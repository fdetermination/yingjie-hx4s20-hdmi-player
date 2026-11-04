`timescale 1ns/1ps
// 共用经验证的Gray同步RAM FIFO，打包{left,right}避免两声道失配。
module pcm_async_fifo #(parameter integer ADDR_BITS=10)(
    input wire wr_clk,rd_clk,rst,wr_valid,
    input wire signed [15:0] wr_left,wr_right,
    output wire wr_ready,
    input wire rd_en,
    output wire rd_empty,rd_valid,
    output wire signed [15:0] rd_left,rd_right,
    output wire [ADDR_BITS:0] wr_used,rd_used
);
    rgb_async_fifo #(.DATA_BITS(32),.ADDR_BITS(ADDR_BITS)) queue(
        .wr_clk(wr_clk),.rd_clk(rd_clk),.rst(rst),.wr_valid(wr_valid),.wr_data({wr_left,wr_right}),
        .wr_ready(wr_ready),.wr_used(wr_used),.rd_en(rd_en),.rd_empty(rd_empty),.rd_valid(rd_valid),
        .rd_data({rd_left,rd_right}),.rd_used(rd_used));
endmodule
