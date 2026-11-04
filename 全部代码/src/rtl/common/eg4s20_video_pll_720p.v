`timescale 1ns/100ps
// 50MHz -> 74.25MHz像素时钟和371.25MHz TMDS串行时钟候选。
// 整数分频和原语综合已核对；模拟环路参数及输出相位仍须IP生成器/布线确认。
// M=20,N=99,C0=3,C1=10,C2=2：VCO=742.5MHz，三路输出分别用于反馈/像素/串行。
module eg4s20_video_pll_720p(
    input wire refclk,reset,
    output wire pixel_clk_74,serial_clk_371,locked
);
    wire feedback_raw,feedback_clk,pixel_raw,serial_raw;
    wire open1,open2;wire [7:0] dynamic_do;wire psdone;
    EG_LOGIC_BUFG feedback_buf(.i(feedback_raw),.o(feedback_clk));
    EG_LOGIC_BUFG pixel_buf(.i(pixel_raw),.o(pixel_clk_74));
    EG_LOGIC_BUFG serial_buf(.i(serial_raw),.o(serial_clk_371));
    EG_PHY_PLL #(
        .DPHASE_SOURCE("DISABLE"),.DYNCFG("DISABLE"),.FIN("50.000000"),
        .FEEDBK_MODE("NORMAL"),.FEEDBK_PATH("CLKC0_EXT"),.STDBY_ENABLE("DISABLE"),
        .PLLRST_ENA("ENABLE"),.SYNC_ENABLE("DISABLE"),.GMC_GAIN(4),.ICP_CURRENT(29),
        .KVCO(4),.LPF_CAPACITOR(1),.LPF_RESISTOR(2),.REFCLK_DIV(20),.FBCLK_DIV(99),
        .CLKC0_ENABLE("ENABLE"),.CLKC0_DIV(3),.CLKC0_CPHASE(2),.CLKC0_FPHASE(0),
        .CLKC1_ENABLE("ENABLE"),.CLKC1_DIV(10),.CLKC1_CPHASE(9),.CLKC1_FPHASE(0),
        .CLKC2_ENABLE("ENABLE"),.CLKC2_DIV(2),.CLKC2_CPHASE(1),.CLKC2_FPHASE(0)
    ) pll(
        .refclk(refclk),.reset(reset),.stdby(1'b0),.extlock(locked),.load_reg(1'b0),
        .psclk(1'b0),.psdown(1'b0),.psstep(1'b0),.psclksel(3'b000),.psdone(psdone),
        .dclk(1'b0),.dcs(1'b0),.dwe(1'b0),.di(8'b0),.daddr(6'b0),.\do (dynamic_do),.fbclk(feedback_clk),
        .clkc({open2,open1,serial_raw,pixel_raw,feedback_raw})
    );
endmodule
