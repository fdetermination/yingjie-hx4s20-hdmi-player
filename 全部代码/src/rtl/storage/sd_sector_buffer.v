`timescale 1ns/1ps
// 独立块接收缓冲：先收齐512字节，再通过同步RAM端口供文件系统查询。
module sd_sector_buffer #(
    parameter integer TIMEOUT_CYCLES=10_000_000
)(
    input wire clk,rst,start,abort,
    input wire [31:0] lba,
    output wire busy,
    output reg done,error,
    output reg [3:0] error_code,
    output wire block_req,
    input wire block_accept,
    output reg [31:0] block_lba,
    input wire block_valid,
    output wire block_ready,
    input wire [7:0] block_data,
    input wire block_last,block_error,
    output wire block_cancel,
    input wire block_cancel_ack,
    input wire word_en,
    input wire [6:0] word_addr,
    output reg [31:0] word_data
);
    localparam IDLE=0,REQUEST=1,RECEIVE=2,CANCEL=3;
    reg [1:0] state;
    reg [31:0] memory[0:127];
    reg [23:0] pack;
    reg [8:0] byte_index;
    reg [31:0] watchdog;
    reg cancelled_by_user;
    assign busy=state!=IDLE;
    assign block_req=state==REQUEST && !abort;
    assign block_ready=state==RECEIVE && !abort;
    assign block_cancel=state==CANCEL;
    always @(posedge clk) begin
        if(word_en) word_data<=memory[word_addr];
        if(block_valid && block_ready && byte_index[1:0]==3)
            memory[byte_index[8:2]]<={block_data,pack};
    end
    task fail;
        input [3:0] code;
        begin state<=CANCEL; error_code<=code; cancelled_by_user<=0; end
    endtask
    always @(posedge clk or posedge rst) begin
        if(rst) begin
            state<=IDLE; done<=0; error<=0; error_code<=0;
            block_lba<=0; byte_index<=0; pack<=0; watchdog<=0; cancelled_by_user<=0;
        end else if(state==CANCEL) begin
            if(abort) cancelled_by_user<=1;
            if(block_cancel_ack) begin
                state<=IDLE; done<=0;
                error<=!(cancelled_by_user || abort);
                if(cancelled_by_user || abort) error_code<=0;
            end
        end else if(abort) begin
            done<=0; error<=0; error_code<=0;
            if(busy) begin state<=CANCEL; cancelled_by_user<=1; end
        end else begin
            case(state)
                IDLE: if(start) begin
                    block_lba<=lba; state<=REQUEST; watchdog<=0; byte_index<=0;
                    done<=0; error<=0; error_code<=0;
                end
                REQUEST: begin
                    if(block_accept) begin state<=RECEIVE; watchdog<=0; end
                    else if(watchdog>=TIMEOUT_CYCLES-1) fail(1);
                    else watchdog<=watchdog+1'b1;
                end
                RECEIVE: begin
                    if(block_error) fail(2);
                    else if(block_valid) begin
                        watchdog<=0;
                        case(byte_index[1:0])
                            0: pack[7:0]<=block_data;
                            1: pack[15:8]<=block_data;
                            2: pack[23:16]<=block_data;
                        endcase
                        if(block_last!=(byte_index==511)) fail(3);
                        else if(byte_index==511) begin state<=IDLE; done<=1; end
                        else byte_index<=byte_index+1'b1;
                    end else if(watchdog>=TIMEOUT_CYCLES-1) fail(4);
                    else watchdog<=watchdog+1'b1;
                end
            endcase
        end
    end
endmodule
