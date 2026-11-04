`timescale 1ns/1ps
// RGB混合 + 小型动态OSD/字幕。字幕文本按低字节为第0字符，支持数字/大写/空格/短横线。
module video_pixel_compositor(
    input wire de,
    input wire [10:0] x,y,
    input wire [23:0] old_rgb,new_rgb,
    input wire [7:0] alpha,
    input wire osd_enable,
    input wire [31:0] osd_value,
    input wire subtitle_enable,
    input wire [127:0] subtitle_text,
    input wire [23:0] osd_color,subtitle_color,
    output reg [23:0] rgb
);
    wire osd_window=osd_enable && x<64 && y<8;
    wire subtitle_window=subtitle_enable && y>=680 && y<688 && x<128;
    wire [3:0] digit=osd_value[(7-x[5:3])*4+:4];
    wire [7:0] osd_char=digit<10?8'h30+digit:8'h41+digit-10;
    wire [7:0] ch=osd_window?osd_char:subtitle_text[x[6:3]*8+:8];
    wire [7:0] glyph_bitmap;
    font8x7 font(.character(ch),.row(y[2:0]),.bitmap(glyph_bitmap));
    function [7:0] mix(input [7:0] a,b,t);
        reg [15:0] product_sum;
        reg [16:0] rounded;
        begin
            product_sum=a*(8'hff-t)+b*t;
            // 对0..65025精确四舍五入除255，常数加法/移位，无通用除法器。
            rounded={1'b0,product_sum}+17'd128;
            rounded=rounded+(rounded>>8);
            mix=rounded[15:8];
        end
    endfunction
    always @(*)begin
        rgb={mix(old_rgb[23:16],new_rgb[23:16],alpha),mix(old_rgb[15:8],new_rgb[15:8],alpha),mix(old_rgb[7:0],new_rgb[7:0],alpha)};
        if(osd_window && glyph_bitmap[7-x[2:0]])rgb=osd_color;
        else if(subtitle_window && glyph_bitmap[7-x[2:0]])rgb=subtitle_color;
        if(!de)rgb=0;
    end
endmodule
