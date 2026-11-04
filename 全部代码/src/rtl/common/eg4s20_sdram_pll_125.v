`timescale 1ns/1ps
// TD生成参数的最小封装：50MHz输入 -> 125MHz控制时钟0° + 125MHz SDRAM时钟180°。
// 仅复用安路PLL物理原语，不包含参考例程的存储/音频/图像架构。
module eg4s20_sdram_pll_125(
    input wire refclk,reset,
    output wire clk_125,
    output wire sdram_clk_125_shift,
    output wire locked
);
    wire feedback_clk;
    wire unused0,unused1,unused2,unused3;
    EG_LOGIC_BUFG feedback_buf(.i(feedback_clk),.o(unused0));
    EG_PHY_PLL #(
        .DPHASE_SOURCE("DISABLE"),.DYNCFG("DISABLE"),.FIN("50.000000"),
        .FEEDBK_MODE("NORMAL"),.FEEDBK_PATH("CLKC0_EXT"),.STDBY_ENABLE("DISABLE"),
        .PLLRST_ENA("ENABLE"),.SYNC_ENABLE("DISABLE"),.GMC_GAIN(4),.ICP_CURRENT(29),
        .KVCO(4),.LPF_CAPACITOR(1),.LPF_RESISTOR(2),.REFCLK_DIV(1),.FBCLK_DIV(2),
        .CLKC0_ENABLE("ENABLE"),.CLKC0_DIV(10),.CLKC0_CPHASE(9),.CLKC0_FPHASE(0),
        .CLKC1_ENABLE("ENABLE"),.CLKC1_DIV(8),.CLKC1_CPHASE(7),.CLKC1_FPHASE(0),
        .CLKC2_ENABLE("ENABLE"),.CLKC2_DIV(8),.CLKC2_CPHASE(3),.CLKC2_FPHASE(0)
    ) pll(
        .refclk(refclk),.reset(reset),.stdby(1'b0),.extlock(locked),.load_reg(1'b0),
        .psclk(1'b0),.psdown(1'b0),.psstep(1'b0),.psclksel(3'b000),.psdone(unused1),
        .dclk(1'b0),.dcs(1'b0),.dwe(1'b0),.di(8'b0),.daddr(6'b0),.\do (),.fbclk(unused0),
        .clkc({unused2,unused3,sdram_clk_125_shift,clk_125,feedback_clk})
    );
endmodule
