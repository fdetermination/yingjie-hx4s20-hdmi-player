`timescale 1ns/100ps
// 50MHz -> 100MHz业务/反馈、125MHz存储、5.125ns PHY和0.625ns独立读采样。
// 参数遵循EG4S20 PLL用户指南的M/N/C反馈模型；实际频率仍由TD布局布线报告确认。
module eg4s20_system_pll(
    input wire refclk,reset,
    output wire clk_100,clk_125,sdram_clk_125_shift,sdram_clk_125_capture,locked
);
    wire feedback_raw,feedback_clk;
    wire clk125_raw,clk125_shift_raw,capture_raw;
    wire open2;wire [7:0] dynamic_do;wire psdone;
    EG_LOGIC_BUFG feedback_buf(.i(feedback_raw),.o(feedback_clk));
    EG_PHY_PLL #(
        .DPHASE_SOURCE("DISABLE"),.DYNCFG("DISABLE"),.FIN("50.000000"),
        .FEEDBK_MODE("NORMAL"),.FEEDBK_PATH("CLKC0_EXT"),.STDBY_ENABLE("DISABLE"),
        .PLLRST_ENA("ENABLE"),.SYNC_ENABLE("DISABLE"),.GMC_GAIN(4),.ICP_CURRENT(29),
        .KVCO(4),.LPF_CAPACITOR(1),.LPF_RESISTOR(2),.REFCLK_DIV(1),.FBCLK_DIV(2),
        .CLKC0_ENABLE("ENABLE"),.CLKC0_DIV(10),.CLKC0_CPHASE(9),.CLKC0_FPHASE(0),
        .CLKC1_ENABLE("ENABLE"),.CLKC1_DIV(8),.CLKC1_CPHASE(7),.CLKC1_FPHASE(0),
        .CLKC2_ENABLE("ENABLE"),.CLKC2_DIV(8),.CLKC2_CPHASE(4),.CLKC2_FPHASE(1),
        .CLKC3_ENABLE("ENABLE"),.CLKC3_DIV(8),.CLKC3_CPHASE(7),.CLKC3_FPHASE(5)
    ) pll(
        .refclk(refclk),.reset(reset),.stdby(1'b0),.extlock(locked),.load_reg(1'b0),
        .psclk(1'b0),.psdown(1'b0),.psstep(1'b0),.psclksel(3'b000),.psdone(psdone),
        .dclk(1'b0),.dcs(1'b0),.dwe(1'b0),.di(8'b0),.daddr(6'b0),.\do (dynamic_do),.fbclk(feedback_clk),
        .clkc({open2,capture_raw,clk125_shift_raw,clk125_raw,feedback_raw})
    );
    assign clk_100=feedback_clk;
    assign clk_125=clk125_raw;
    assign sdram_clk_125_shift=clk125_shift_raw;
    assign sdram_clk_125_capture=capture_raw;
endmodule
