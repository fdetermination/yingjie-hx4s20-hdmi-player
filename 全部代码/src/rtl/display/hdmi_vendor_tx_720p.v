`timescale 1ns/1ps
// 仅封装主办方提供的HDMI协议IP，应用播放/存储/图片/音频均由自主RTL完成。
// 视频接口必须在开始一行前预留完整1280像素，行内连续；详情见APUG092 2.4.2。
module hdmi_vendor_tx_720p #(
    parameter integer PIXEL_HZ=74250000
)(
    input wire clk,rst,
    input wire video_valid,video_sof,video_eol,
    input wire [23:0] video_rgb,
    output wire video_ready,
    input wire sample_valid,
    input wire signed [15:0] sample_left,sample_right,
    input wire edid_start,
    output wire edid_valid,
    output wire [7:0] edid_data,
    output wire video_locked,ddc_scl,
    inout wire ddc_sda,
    output wire [9:0] tmds0,tmds1,tmds2,tmds_clock
);
    wire audio_valid,acr_valid;
    wire [23:0] audio_left,audio_right;
    wire [19:0] acr_n,acr_cts;
    hdmi_pcm_acr_adapter #(.PIXEL_HZ(PIXEL_HZ)) pcm_adapter(
        .clk(clk),.rst(rst),.sample_valid(sample_valid),.sample_left(sample_left),.sample_right(sample_right),
        .audio_valid(audio_valid),.audio_left(audio_left),.audio_right(audio_right),
        .acr_valid(acr_valid),.acr_n(acr_n),.acr_cts(acr_cts));
    hdmi_1_4b_transmitter_core_wrapper #(
        .DEVICE("EG"),.HTOTAL(1650),.HSA(40),.HFP(110),.HBP(220),.HACTIVE(1280),
        .VTOTAL(750),.VSA(5),.VFP(5),.VBP(20),.VACTIVE(720),.VIDEO_VIC(4),
        .VIDEO_TPG("Disable"),.VIDEO_FORMAT("RGB"),.AUDIO_SAMPLE_RATE("48K"),
        .IIC_SCL_DIV((PIXEL_HZ+199999)/200000)
    ) protocol_ip(
        .I_pixel_clk(clk),.I_rst(rst),.I_edid_read_trig(edid_start),.O_edid_read_valid(edid_valid),.O_edid_read_data(edid_data),
        .I_axis_s_user(video_sof),.I_axis_s_valid(video_valid),.I_axis_s_last(video_eol),.I_axis_s_data(video_rgb),.O_axis_s_ready(video_ready),
        .I_audio_valid(audio_valid),.I_audio_left_data(audio_left),.I_audio_right_data(audio_right),
        .I_acr_valid(acr_valid),.I_acr_cts(acr_cts),.I_acr_n(acr_n),.O_video_locked(video_locked),
        .O_ddc_scl(ddc_scl),.IO_ddc_sda(ddc_sda),.O_ch0_tmds_data(tmds0),.O_ch1_tmds_data(tmds1),
        .O_ch2_tmds_data(tmds2),.O_clk_tmds_data(tmds_clock));
endmodule
