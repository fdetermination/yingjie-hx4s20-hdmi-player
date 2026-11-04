`timescale 1ns/1ps
// 安路合封SDRAM原语封装：命令调度由自主控制器实现，原语只提供物理存储接口。
module eg4s20_sdram_backend(
    input wire clk,sdram_phy_clk,sdram_capture_clk,rst,
    input wire cmd_valid,cmd_write,
    output wire cmd_ready,
    input wire [20:0] cmd_addr,
    input wire [8:0] cmd_len,
    input wire wr_valid,
    output wire wr_ready,
    input wire [31:0] wr_data,
    input wire [3:0] wr_mask,
    output wire rd_valid,rd_last,
    output wire [31:0] rd_data,
    input wire rd_ready,
    output wire done,error,
    output wire [3:0] error_code,
    input wire abort,
    output wire cancel_ack,init_done,busy
);
    wire cke,cs_n,ras_n,cas_n,we_n;
    wire [10:0] addr;
    wire [1:0] ba;
    wire [3:0] dm;
    wire [31:0] dq;
    sdram_cmd_controller controller(
        .clk(clk),.read_capture_clk(sdram_capture_clk),.rst(rst),.cmd_valid(cmd_valid),.cmd_ready(cmd_ready),.cmd_write(cmd_write),
        .cmd_addr(cmd_addr),.cmd_len(cmd_len),.wr_valid(wr_valid),.wr_ready(wr_ready),.wr_data(wr_data),.wr_mask(wr_mask),
        .rd_valid(rd_valid),.rd_data(rd_data),.rd_last(rd_last),.rd_ready(rd_ready),
        .done(done),.error(error),.error_code(error_code),.abort(abort),.cancel_ack(cancel_ack),.init_done(init_done),.busy(busy),
        .sdram_cke(cke),.sdram_cs_n(cs_n),.sdram_ras_n(ras_n),.sdram_cas_n(cas_n),.sdram_we_n(we_n),
        .sdram_addr(addr),.sdram_ba(ba),.sdram_dq(dq),.sdram_dm(dm));
    EG_PHY_SDRAM_2M_32 memory(.clk(sdram_phy_clk),.ras_n(ras_n),.cas_n(cas_n),.we_n(we_n),.addr(addr),.ba(ba),
        .dq(dq),.cs_n(cs_n),.dm0(dm[0]),.dm1(dm[1]),.dm2(dm[2]),.dm3(dm[3]),.cke(cke));
endmodule
