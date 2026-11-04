`timescale 1ns/1ps
// 三客户端、两文件槽；端口0位于packed总线低位。
module media_file_arbiter(
    input wire clk,rst,flush_req,
    output reg flush_ack,
    input wire [2:0] client_cmd_valid,client_abort,client_urgent,
    output wire [2:0] client_cmd_ready,
    input wire [8:0] client_cmd_op,
    input wire [2:0] client_cmd_channel,
    input wire [83:0] client_cmd_cluster,
    input wire [95:0] client_cmd_size,
    output reg [2:0] client_done,client_error,client_open_complete,client_cancel_ack,
    output wire [2:0] client_data_valid,
    input wire [2:0] client_data_ready,
    output wire [7:0] client_data_byte,
    output wire client_file_last,
    output wire service_cmd_valid,
    input wire service_cmd_ready,
    output reg [2:0] service_cmd_op,
    output reg service_cmd_channel,
    output reg [27:0] service_cmd_cluster,
    output reg [31:0] service_cmd_size,
    input wire service_done,service_error,service_open_complete,service_cancel_ack,
    output wire service_abort,
    input wire service_data_valid,service_file_last,
    input wire [7:0] service_data_byte,
    output wire service_data_ready,
    output wire owner_valid,
    output reg [1:0] owner
);
    localparam IDLE=0,ISSUE=1,RESPONSE=2,CANCEL=3,RELEASE=4,RESERVE=5;
    reg [2:0] state;
    reg [1:0] background_next,urgent_next,urgent_streak;
    reg reserved_urgent;
    wire [2:0] eligible=client_cmd_valid & ~client_abort & ~client_cancel_ack;
    wire [2:0] urgent=eligible & client_urgent;
    wire [2:0] background=eligible & ~client_urgent;
    wire choose_urgent=|urgent && !(urgent_streak==2 && |background);
    wire [2:0] candidates=choose_urgent?urgent:background;
    function [1:0] choose;
        input [2:0] requests;
        input [1:0] next_client;
        begin
            case(next_client)
                0:choose=requests[0]?0:(requests[1]?1:(requests[2]?2:3));
                1:choose=requests[1]?1:(requests[2]?2:(requests[0]?0:3));
                default:choose=requests[2]?2:(requests[0]?0:(requests[1]?1:3));
            endcase
        end
    endfunction
    wire [1:0] selected=choose(candidates,choose_urgent?urgent_next:background_next);
    assign owner_valid=(state==ISSUE || state==RESPONSE || state==CANCEL) && !rst;
    assign client_cmd_ready=state==RESERVE && eligible[owner] && !flush_req && !rst?(3'b001<<owner):3'b000;
    assign service_cmd_valid=state==ISSUE && !client_abort[owner] && !flush_req && !rst;
    assign service_abort=state==CANCEL && !rst;
    wire deliver=state==RESPONSE && !client_abort[owner] && !flush_req && !rst;
    assign client_data_valid=deliver && service_data_valid?(3'b001<<owner):3'b000;
    assign service_data_ready=deliver && client_data_ready[owner];
    assign client_data_byte=service_data_byte;
    assign client_file_last=service_file_last;
    integer i;
    always @(posedge clk or posedge rst)begin
        if(rst)begin
            state<=IDLE;owner<=0;background_next<=0;urgent_next<=0;urgent_streak<=0;
            reserved_urgent<=0;
            flush_ack<=0;client_done<=0;client_error<=0;client_open_complete<=0;client_cancel_ack<=0;
            service_cmd_op<=0;service_cmd_channel<=0;service_cmd_cluster<=0;service_cmd_size<=0;
        end else begin
            if(!flush_req)flush_ack<=0;
            for(i=0;i<3;i=i+1)begin
                if(!client_abort[i])client_cancel_ack[i]<=0;
                else begin
                    client_done[i]<=0;client_error[i]<=0;client_open_complete[i]<=0;
                    if(!owner_valid || owner!=i)client_cancel_ack[i]<=1;
                end
            end
            if(flush_req)begin client_done<=0;client_error<=0;client_open_complete<=0;urgent_streak<=0;end
            case(state)
                IDLE:if(flush_req)flush_ack<=1;
                     else if(selected!=3)begin
                         owner<=selected;reserved_urgent<=choose_urgent;state<=RESERVE;
                     end
                RESERVE:if(flush_req)begin state<=IDLE;flush_ack<=1;end
                     else if(!eligible[owner])state<=IDLE;
                     else begin
                         service_cmd_op<=client_cmd_op[owner*3+:3];
                         service_cmd_channel<=client_cmd_channel[owner];
                         service_cmd_cluster<=client_cmd_cluster[owner*28+:28];service_cmd_size<=client_cmd_size[owner*32+:32];
                         client_done[owner]<=0;client_error[owner]<=0;client_open_complete[owner]<=0;state<=ISSUE;
                         // urgent和后台分别轮转，避免urgent重复把后台起点重置到同一端口。
                         if(reserved_urgent)begin
                             urgent_next<=owner==2?0:owner+1'b1;
                             if(urgent_streak<2)urgent_streak<=urgent_streak+1'b1;
                         end else begin background_next<=owner==2?0:owner+1'b1;urgent_streak<=0;end
                     end
                ISSUE:if(flush_req || client_abort[owner])begin
                          state<=RELEASE;client_cancel_ack[owner]<=client_abort[owner];
                          if(flush_req)flush_ack<=1;
                      end else if(service_cmd_valid && service_cmd_ready)state<=RESPONSE;
                RESPONSE:if(flush_req || client_abort[owner])begin
                             if(service_done || service_error)begin
                                 state<=RELEASE;client_cancel_ack[owner]<=client_abort[owner];
                                 if(flush_req)flush_ack<=1;
                             end else state<=CANCEL;
                         end else if(service_done || service_error)begin
                             client_done[owner]<=service_done && !service_error;client_error[owner]<=service_error;
                             client_open_complete[owner]<=service_done && !service_error && service_open_complete &&
                                 (service_cmd_op==2 || service_cmd_op==4 || service_cmd_op==5);
                             state<=IDLE;
                         end
                CANCEL:if(service_cancel_ack)begin
                           state<=RELEASE;client_cancel_ack[owner]<=1;
                           if(flush_req)flush_ack<=1;
                       end
                RELEASE:begin
                    // 排空ack不等待重新挂载ready；ready只限制下一次物理命令。
                    if(flush_req)flush_ack<=1;
                    else if(service_cmd_ready)state<=IDLE;
                end
            endcase
        end
    end
endmodule
