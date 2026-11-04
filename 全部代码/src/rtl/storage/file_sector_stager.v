`timescale 1ns/1ps
// 图片客户端扇区暂存：先完整接收物理READ，释放服务所有权，再独立受BMP背压消费。
// 一条命令在途；下游done保持到新命令；本地排空取消不得取消另一个文件客户端。
module file_sector_stager(
    input wire clk,rst,app_abort,app_cmd_valid,
    output wire app_cmd_ready,
    input wire [2:0] app_cmd_op,
    input wire app_cmd_channel,
    input wire [27:0] app_cmd_cluster,
    input wire [31:0] app_cmd_size,
    output reg app_done,app_error,app_open_complete,
    output wire app_cancel_ack,app_data_valid,app_file_last,
    output wire [7:0] app_data_byte,
    input wire app_data_ready,
    output wire service_cmd_valid,
    output reg [2:0] service_cmd_op,
    output reg service_cmd_channel,
    output reg [27:0] service_cmd_cluster,
    output reg [31:0] service_cmd_size,
    input wire service_cmd_ready,service_done,service_error,service_cancel_ack,service_open_complete,
    output wire service_abort,service_inflight,
    input wire service_data_valid,service_file_last,
    input wire [7:0] service_data_byte,
    output wire service_data_ready
);
    localparam IDLE=0,COMMAND=1,RESPONSE=2,FETCH=3,DRAIN=4,CANCEL=5,CANCEL_DONE=6;
    reg [2:0] state;
    reg [9:0] count,read_index;
    (* ram_style="bram" *) reg [8:0] bytes[0:511];
    reg [8:0] held_byte;
    reg malformed_cancel,last_received;
    wire accepted_byte=service_data_valid && service_data_ready;
    wire block_full_after_byte=count[9] || (accepted_byte && (&count[8:0]));
    assign app_cmd_ready=state==IDLE && !app_abort && !rst;
    assign service_cmd_valid=state==COMMAND && !app_abort;
    assign service_inflight=state==COMMAND || state==RESPONSE || state==CANCEL;
    assign service_data_ready=state==RESPONSE && service_cmd_op==3 && count<512 && !app_abort;
    assign app_data_valid=state==DRAIN && !app_abort;
    assign app_data_byte=held_byte[7:0];
    assign app_file_last=held_byte[8];
    assign service_abort=state==CANCEL;
    assign app_cancel_ack=state==CANCEL_DONE;
    always @(posedge clk)begin
        if(accepted_byte)bytes[count[8:0]]<={service_file_last,service_data_byte};
        if(state==FETCH)held_byte<=bytes[read_index[8:0]];
    end
    always @(posedge clk or posedge rst)begin
        if(rst)begin
            state<=IDLE;count<=0;read_index<=0;app_done<=0;app_error<=0;app_open_complete<=0;malformed_cancel<=0;last_received<=0;
            service_cmd_op<=0;service_cmd_channel<=0;service_cmd_cluster<=0;service_cmd_size<=0;
        end else if(app_abort && state!=CANCEL && state!=CANCEL_DONE)begin
            // COMMAND尚未接受，FETCH/DRAIN已释放服务，可在本地取消。
            // RESPONSE终态与取消同拍时物理事务已结束，不能在下一拍abort新的仲裁owner。
            state<=(state==RESPONSE && !service_done && !service_error)?CANCEL:CANCEL_DONE;
            count<=0;app_done<=0;app_error<=0;app_open_complete<=0;malformed_cancel<=0;
        end else case(state)
            IDLE:if(app_cmd_valid && app_cmd_ready)begin
                service_cmd_op<=app_cmd_op;service_cmd_channel<=app_cmd_channel;
                service_cmd_cluster<=app_cmd_cluster;service_cmd_size<=app_cmd_size;
                count<=0;read_index<=0;app_done<=0;app_error<=0;app_open_complete<=0;malformed_cancel<=0;last_received<=0;state<=COMMAND;
            end
            COMMAND:if(service_cmd_valid && service_cmd_ready)state<=RESPONSE;
            RESPONSE:begin
                if(accepted_byte)begin count<=count+1'b1;last_received<=service_file_last;end
                if(service_error)begin app_error<=1;count<=0;state<=IDLE;end
                else if(service_data_valid && (service_cmd_op!=3 || count==512 || last_received))begin
                    if(service_done)begin app_error<=1;count<=0;state<=IDLE;end
                    else begin malformed_cancel<=1;state<=CANCEL;end
                end
                else if(service_done)begin
                    if(service_cmd_op==3 && (count!=0 || accepted_byte) &&
                        !block_full_after_byte && !(last_received || (accepted_byte && service_file_last)))begin
                        app_error<=1;count<=0;state<=IDLE;
                    end else if(service_cmd_op==3 && (count!=0 || accepted_byte))begin read_index<=0;state<=FETCH;end
                    else begin
                        app_done<=1;state<=IDLE;
                        app_open_complete<=service_open_complete && (service_cmd_op==2 || service_cmd_op==4 || service_cmd_op==5);
                    end
                end
            end
            FETCH:state<=DRAIN;
            DRAIN:if(app_data_ready)begin
                if(read_index+1==count)begin state<=IDLE;app_done<=1;end
                else begin read_index<=read_index+1'b1;state<=FETCH;end
            end
            CANCEL:if(service_cancel_ack)begin
                if(malformed_cancel && !app_abort)begin app_error<=1;count<=0;state<=IDLE;end
                else begin app_error<=0;app_done<=0;state<=CANCEL_DONE;end
            end
            CANCEL_DONE:if(!app_abort)state<=IDLE;
        endcase
    end
endmodule
