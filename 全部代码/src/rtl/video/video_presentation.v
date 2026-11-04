`timescale 1ns/1ps
// 控制域配置 -> 整帧快照 -> 颜色/字幕流水 -> 状态/频谱HUD。
// frame_start在像素输入(0,0)之前一拍到达；音频输入必须为实际播放48kHz样本。
module video_presentation #(parameter integer SPECTRUM_VISUAL_ENABLE=0)(
    input wire mem_clk,pixel_clk,rst,frame_start,
    input wire de_in,hs_in,vs_in,
    input wire [10:0] x_in,y_in,
    input wire [23:0] rgb0,rgb1,
    input wire scene_valid_in,
    input wire [7:0] scene_token_in,
    output wire scene_valid_out,
    output wire [7:0] scene_token_out,
    input wire [7:0] alpha,
    input wire osd_enable,subtitle_enable,spectrum_enable,menu_open,
    input wire [2:0] menu_item,
    input wire [1:0] interval_sel,
    input wire [15:0] playback_status,
    input wire signed [8:0] brightness,
    input wire [7:0] contrast,
    input wire [127:0] subtitle_text,
    input wire [23:0] subtitle_color,
    input wire sample_valid,
    input wire signed [15:0] sample_left,sample_right,
    output wire spectrum_overrun,de_out,hs_out,vs_out,
    output wire [10:0] x_out,y_out,
    output wire [23:0] rgb_out
);
    localparam CONFIG_BITS=194;
    wire [CONFIG_BITS-1:0] source_config={osd_enable,subtitle_enable,spectrum_enable,menu_open,menu_item,
        interval_sel,playback_status,brightness,contrast,subtitle_text,subtitle_color};
    wire [CONFIG_BITS-1:0] pixel_config;
    wire pixel_rst,cfg_osd,cfg_subtitle,cfg_spectrum,cfg_menu;
    wire [2:0] cfg_item;wire [1:0] cfg_interval;wire [15:0] cfg_status;
    wire signed [8:0] cfg_brightness;wire [7:0] cfg_contrast;
    wire [127:0] cfg_text;wire [23:0] cfg_color;
    wire [10:0] shift;
    wire bins_valid;wire [127:0] levels;
    wire processed_de,processed_hs,processed_vs;wire [10:0] processed_x,processed_y;wire [23:0] processed_rgb;
    wire processed_scene_valid;wire [7:0] processed_scene_token;
    assign {cfg_osd,cfg_subtitle,cfg_spectrum,cfg_menu,cfg_item,cfg_interval,cfg_status,cfg_brightness,cfg_contrast,cfg_text,cfg_color}=pixel_config;
    reset_sync pixel_reset(.clk(pixel_clk),.rst_in(rst),.rst_out(pixel_rst));
    frame_config_cdc #(.WIDTH(CONFIG_BITS),.RESET_VALUE({4'd0,3'd0,2'd0,16'd0,9'd0,8'd128,128'd0,24'h00ff00})) config_cdc(
        .src_clk(mem_clk),.dst_clk(pixel_clk),.rst(rst),.src_data(source_config),.frame_start(frame_start),.dst_data(pixel_config),.busy());
    subtitle_scroll_ctrl scroll(.clk(pixel_clk),.rst(pixel_rst),.frame_start(frame_start),
        .enable(cfg_subtitle),.restart(1'b0),.pixels_per_step(4'd2),.shift(shift));
    audio_spectrum_goertzel spectrum(.clk(pixel_clk),.rst(pixel_rst),.sample_valid(sample_valid),
        .sample_left(sample_left),.sample_right(sample_right),.sample_ready(),.overrun(spectrum_overrun),.bins_valid(bins_valid),.levels(levels));
    video_pixel_pipeline pixels(.clk(pixel_clk),.rst(pixel_rst),.de_in(de_in),.hs_in(hs_in),.vs_in(vs_in),
        .x_in(x_in),.y_in(y_in),.rgb0(rgb0),.rgb1(rgb1),.alpha(alpha),.contrast(cfg_contrast),.brightness(cfg_brightness),
        .scene_valid_in(scene_valid_in),.scene_token_in(scene_token_in),.scene_valid_out(processed_scene_valid),.scene_token_out(processed_scene_token),
        .osd_enable(1'b0),.osd_value(32'd0),.subtitle_enable(cfg_subtitle),.subtitle_text(cfg_text),.subtitle_shift(shift),
        .osd_color(24'hffffff),.subtitle_color(cfg_color),.de_out(processed_de),.hs_out(processed_hs),.vs_out(processed_vs),
        .x_out(processed_x),.y_out(processed_y),.rgb_out(processed_rgb));
    video_hud #(.SPECTRUM_VISUAL_ENABLE(SPECTRUM_VISUAL_ENABLE)) hud(.clk(pixel_clk),.rst(pixel_rst),.frame_start(frame_start),.bins_valid(bins_valid),.levels(levels),
        .de_in(processed_de),.hs_in(processed_hs),.vs_in(processed_vs),.x_in(processed_x),.y_in(processed_y),.rgb_in(processed_rgb),
        .scene_valid_in(processed_scene_valid),.scene_token_in(processed_scene_token),.scene_valid_out(scene_valid_out),.scene_token_out(scene_token_out),
        .osd_enable(cfg_osd),.spectrum_enable(cfg_spectrum),.menu_open(cfg_menu),.menu_item(cfg_item),.interval_sel(cfg_interval),
        .playback_status(cfg_status),.brightness(cfg_brightness),.contrast(cfg_contrast),.subtitle_enable(cfg_subtitle),
        .de_out(de_out),.hs_out(hs_out),.vs_out(vs_out),.x_out(x_out),.y_out(y_out),.rgb_out(rgb_out));
endmodule
