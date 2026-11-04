`timescale 1ns/1ps
// APUG092 §2.4.3/2.4.4：pixel_clk域PCM/ACR输入，无I2S往返转换。
// PIXEL_HZ必须等于实际像素PLL输出；固定48kHz，N=6144 => CTS=PIXEL_HZ/1000。
module hdmi_pcm_acr_adapter #(parameter integer PIXEL_HZ=74250000)(
    input wire clk,rst,sample_valid,
    input wire signed [15:0] sample_left,sample_right,
    output reg audio_valid,acr_valid,
    output reg [23:0] audio_left,audio_right,
    output wire [19:0] acr_n,acr_cts
);
    reg [5:0] sample_counter;
    assign acr_n=20'd6144;
    assign acr_cts=PIXEL_HZ/1000;
    always @(posedge clk or posedge rst)begin
        if(rst)begin sample_counter<=0;audio_valid<=0;acr_valid<=0;audio_left<=0;audio_right<=0;end
        else begin
            audio_valid<=sample_valid;acr_valid<=0;
            if(sample_valid)begin
                audio_left<={sample_left,8'b0};audio_right<={sample_right,8'b0};
                if(sample_counter==47)begin sample_counter<=0;acr_valid<=1;end
                else sample_counter<=sample_counter+1'b1;
            end
        end
    end
endmodule
