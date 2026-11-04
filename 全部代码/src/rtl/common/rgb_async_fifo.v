`timescale 1ns/1ps
// 双时钟同步RAM像素FIFO。rd_en且非空在上升沿出队，rd_valid/data在该沿后有效一拍。
// rst必须共同异步置位；各时钟域独立同步释放。epoch切换须先停流再共同清空。
module rgb_async_fifo #(
    parameter integer DATA_BITS=24,ADDR_BITS=12
)(
    input wire wr_clk,rd_clk,rst,
    input wire wr_valid,
    input wire [DATA_BITS-1:0] wr_data,
    output wire wr_ready,
    output reg [ADDR_BITS:0] wr_used,
    input wire rd_en,
    output wire rd_empty,
    output reg rd_valid,
    output reg [DATA_BITS-1:0] rd_data,
    output reg [ADDR_BITS:0] rd_used
);
    localparam DEPTH=1<<ADDR_BITS;
    (* ram_style="bram" *) reg [DATA_BITS-1:0] memory[0:DEPTH-1];
    reg [ADDR_BITS:0] wr_bin,wr_gray,rd_bin,rd_gray;
    // 预先保存下一写指针，切开full反馈经过加法器的关键路径。
    reg [ADDR_BITS:0] wr_increment;
    (* async_reg="true" *) reg [ADDR_BITS:0] rd_gray_meta,rd_gray_sync,wr_gray_meta,wr_gray_sync;
    (* async_reg="true" *) reg [1:0] wr_reset_pipe,rd_reset_pipe;
    reg full,empty;
    wire wr_reset=wr_reset_pipe[1],rd_reset=rd_reset_pipe[1];
    wire write_take=wr_valid && wr_ready;
    wire read_take=rd_en && !rd_empty;
    // 指针寄存器已有域内reset门控，前瞻运算不再串入复位组合路径。
    wire [ADDR_BITS:0] wr_next=wr_bin+(wr_valid && !full),rd_next=rd_bin+(rd_en && !empty);
    wire [ADDR_BITS:0] wr_next_gray=(wr_next>>1)^wr_next;
    wire [ADDR_BITS:0] rd_next_gray=(rd_next>>1)^rd_next;
    wire [ADDR_BITS:0] increment_gray=(wr_increment>>1)^wr_increment;
    wire [ADDR_BITS:0] full_target={~rd_gray_sync[ADDR_BITS:ADDR_BITS-1],rd_gray_sync[ADDR_BITS-2:0]};
    function [ADDR_BITS:0] gray_to_binary(input [ADDR_BITS:0] gray);
        integer k;
        begin
            gray_to_binary[ADDR_BITS]=gray[ADDR_BITS];
            for(k=ADDR_BITS-1;k>=0;k=k-1)gray_to_binary[k]=gray_to_binary[k+1]^gray[k];
        end
    endfunction
    assign wr_ready=!wr_reset && !full;
    assign rd_empty=rd_reset || empty;
    // 写侧占用是保守上界，读侧可读数是保守下界；跨域指针须经两级同步。
    always @(posedge wr_clk or posedge rst)
        if(rst)wr_reset_pipe<=2'b11;else wr_reset_pipe<={wr_reset_pipe[0],1'b0};
    always @(posedge rd_clk or posedge rst)
        if(rst)rd_reset_pipe<=2'b11;else rd_reset_pipe<={rd_reset_pipe[0],1'b0};
    always @(posedge wr_clk)if(write_take)memory[wr_bin[ADDR_BITS-1:0]]<=wr_data;
    // 数据寄存器不复位以保持块RAM推断，复位后仅rd_valid决定数据有效。
    always @(posedge rd_clk)if(read_take)rd_data<=memory[rd_bin[ADDR_BITS-1:0]];
    always @(posedge wr_clk or posedge wr_reset)begin
        if(wr_reset)begin wr_bin<=0;wr_increment<=1;wr_gray<=0;full<=0;rd_gray_meta<=0;rd_gray_sync<=0;wr_used<=0;end
        else begin
            rd_gray_meta<=rd_gray;rd_gray_sync<=rd_gray_meta;
            wr_bin<=wr_next;wr_gray<=wr_next_gray;
            if(wr_valid && !full)wr_increment<=wr_increment+1'b1;
            wr_used<=wr_next-gray_to_binary(rd_gray_sync);
            full<=(wr_valid && !full)?increment_gray==full_target:wr_gray==full_target;
        end
    end
    always @(posedge rd_clk or posedge rd_reset)begin
        if(rd_reset)begin rd_bin<=0;rd_gray<=0;empty<=1;wr_gray_meta<=0;wr_gray_sync<=0;rd_valid<=0;rd_used<=0;end
        else begin
            wr_gray_meta<=wr_gray;wr_gray_sync<=wr_gray_meta;
            rd_bin<=rd_next;rd_gray<=rd_next_gray;empty<=rd_next_gray==wr_gray_sync;rd_valid<=read_take;
            rd_used<=gray_to_binary(wr_gray_sync)-rd_next;
        end
    end
endmodule
