`timescale 1ns/1ps
// 整帧配置mailbox：源端payload保持至帧边界确认，忙期间只合并最新输入。
// rst必须共同置位，释放分别同步；SDC须约束payload到目标寄存器的总线延迟。
module frame_config_cdc #(
    parameter integer WIDTH=32,
    parameter [WIDTH-1:0] RESET_VALUE=0
)(
    input wire src_clk,dst_clk,rst,
    input wire [WIDTH-1:0] src_data,
    input wire frame_start,
    output wire [WIDTH-1:0] dst_data,
    output wire busy
);
    wire src_rst,dst_rst;
    reg [WIDTH-1:0] mailbox;
    reg [WIDTH-1:0] received;
    reg received_valid;
    reg request_toggle,ack_toggle,sent,changed;
    (* async_reg="true" *) reg request_meta,request_sync,ack_meta,ack_sync;
    reset_sync src_reset(.clk(src_clk),.rst_in(rst),.rst_out(src_rst));
    reset_sync dst_reset(.clk(dst_clk),.rst_in(rst),.rst_out(dst_rst));
    assign busy=request_toggle!=ack_sync;
    assign dst_data=received_valid?received:RESET_VALUE;
    // payload只在握手后可见；异步复位只分发给控制位，降低宽总线SR扇出。
    always @(posedge src_clk)
        if(!src_rst && !busy && (!sent || changed))mailbox<=src_data;
    always @(posedge dst_clk)
        if(!dst_rst && frame_start && request_sync!=ack_toggle)received<=mailbox;
    always @(posedge src_clk or posedge src_rst)begin
        if(src_rst)begin request_toggle<=0;ack_meta<=0;ack_sync<=0;sent<=0;changed<=0;end
        else begin
            ack_meta<=ack_toggle;ack_sync<=ack_meta;
            // 宽总线变化比较先寄存，再驱动握手和payload使能。
            changed<=src_data!=mailbox;
            if(!busy && (!sent || changed))begin
                request_toggle<=~request_toggle;sent<=1;
            end
        end
    end
    always @(posedge dst_clk or posedge dst_rst)begin
        if(dst_rst)begin request_meta<=0;request_sync<=0;ack_toggle<=0;received_valid<=0;end
        else begin
            request_meta<=request_toggle;request_sync<=request_meta;
            if(frame_start && request_sync!=ack_toggle)begin received_valid<=1;ack_toggle<=request_sync;end
        end
    end
endmodule
