`timescale 1ns/1ps
// HX4S20C物理顶层：只负责时钟、复位、按键/TF/HDMI引脚和自主系统核心边界。
// 物理时序/转场仍在集成；完成布局布线验收后再用于下载。
module yingjie_hx4s20_top #(
    parameter integer DEBOUNCE_CYCLES=2000000,HOLD_CYCLES=80000000,RESTART_CYCLES=200000000,
    parameter integer BILINEAR_ENABLE=1,
    parameter integer SPECTRUM_VISUAL_ENABLE=BILINEAR_ENABLE
)(
    input wire clk_50,rst_n,
    input wire key_next,key_auto,
    input wire sd_miso,
    output wire sd_cs_n,sd_sclk,sd_mosi,
    output wire hdmi_clk_p,hdmi_d0_p,hdmi_d1_p,hdmi_d2_p,
    output wire hdmi_ddc_scl,
    inout wire hdmi_ddc_sda,
    output wire [3:0] status_led
);
    wire ctrl_clk,mem_clk,pixel_clk,sdram_phy_clk,sdram_capture_clk,serial_clk;
    wire sys_locked,video_locked_pll;
    wire reset_async,core_rst,serial_rst;
    wire [9:0] tmds0,tmds1,tmds2,tmds_clock;
    wire edid_valid;wire [7:0] edid_data;
    wire app_busy;wire [3:0] app_error;wire video_underflow,video_fault,audio_underflow,hdmi_locked;
    wire key_next_active,key_auto_active,restart_request,menu_open,subtitle_enable,spectrum_enable,spectrum_overrun;
    wire [1:0] interval_sel;wire [2:0] menu_item;
    wire signed [8:0] brightness;wire [7:0] contrast;
    function [127:0] subtitle_bytes(input [127:0] text);
        integer c;begin for(c=0;c<16;c=c+1)subtitle_bytes[c*8+:8]=text[(15-c)*8+:8];end
    endfunction
    eg4s20_system_pll sys_pll(.refclk(clk_50),.reset(!rst_n),.clk_100(ctrl_clk),.clk_125(mem_clk),.sdram_clk_125_shift(sdram_phy_clk),.sdram_clk_125_capture(sdram_capture_clk),.locked(sys_locked));
    eg4s20_video_pll_720p video_pll(.refclk(clk_50),.reset(!rst_n),.pixel_clk_74(pixel_clk),.serial_clk_371(serial_clk),.locked(video_locked_pll));
    assign reset_async=!rst_n || !sys_locked || !video_locked_pll;
    reset_sync core_reset(.clk(ctrl_clk),.rst_in(reset_async),.rst_out(core_rst));
    reset_sync serial_reset(.clk(serial_clk),.rst_in(reset_async),.rst_out(serial_rst));
    board_ui_ctrl #(.DEBOUNCE_CYCLES(DEBOUNCE_CYCLES),.HOLD_CYCLES(HOLD_CYCLES),.RESTART_CYCLES(RESTART_CYCLES)) ui(
        .clk(ctrl_clk),.rst(core_rst),.key_next_n(key_next),.key_auto_n(key_auto),.next_pulse(key_next_active),.auto_pulse(key_auto_active),
        .restart_pulse(restart_request),.menu_open(menu_open),.menu_item(menu_item),.interval_sel(interval_sel),
        .brightness(brightness),.contrast(contrast),.subtitle_enable(subtitle_enable),.spectrum_enable(spectrum_enable));
    yingjie_system_core #(.CLK_FREQ_HZ(100000000),.BILINEAR_ENABLE(BILINEAR_ENABLE),.SPECTRUM_VISUAL_ENABLE(SPECTRUM_VISUAL_ENABLE)) core(
        .ctrl_clk(ctrl_clk),.mem_clk(mem_clk),.pixel_clk(pixel_clk),.rst(core_rst),.restart(restart_request),
        .key_next(key_next_active),.key_auto(key_auto_active),.interval_sel(interval_sel),.sdram_phy_clk(sdram_phy_clk),.sdram_capture_clk(sdram_capture_clk),.sd_miso(sd_miso),
        .sd_cs_n(sd_cs_n),.sd_sclk(sd_sclk),.sd_mosi(sd_mosi),.edid_start(1'b0),.osd_enable(1'b1),
        .subtitle_enable(subtitle_enable),.subtitle_text(subtitle_bytes("YINGJIE FPGA    ")),.subtitle_color(24'hffffff),
        .brightness(brightness),.contrast(contrast),.spectrum_enable(spectrum_enable),.menu_open(menu_open),.menu_item(menu_item),.spectrum_overrun(spectrum_overrun),
        .tmds0(tmds0),.tmds1(tmds1),.tmds2(tmds2),.tmds_clock(tmds_clock),.edid_valid(edid_valid),.edid_data(edid_data),
        .ddc_scl(hdmi_ddc_scl),.ddc_sda(hdmi_ddc_sda),.app_busy(app_busy),.app_error(app_error),.video_underflow(video_underflow),.video_fault(video_fault),.audio_underflow(audio_underflow),.hdmi_locked(hdmi_locked));
    hdmi_serial_lane lane0(.serial_clk(serial_clk),.rst(serial_rst),.code(tmds0),.pad(hdmi_d0_p));
    hdmi_serial_lane lane1(.serial_clk(serial_clk),.rst(serial_rst),.code(tmds1),.pad(hdmi_d1_p));
    hdmi_serial_lane lane2(.serial_clk(serial_clk),.rst(serial_rst),.code(tmds2),.pad(hdmi_d2_p));
    hdmi_serial_lane lane_clock(.serial_clk(serial_clk),.rst(serial_rst),.code(tmds_clock),.pad(hdmi_clk_p));
    assign status_led[0]=app_error!=0;
    assign status_led[1]=app_busy;
    assign status_led[2]=video_fault || video_underflow;
    assign status_led[3]=audio_underflow || spectrum_overrun || !hdmi_locked;
endmodule
