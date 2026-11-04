`timescale 1ns/1ps
// 5拍像素流水：双帧乘法 -> 求和 -> 四舍五入/对比度 -> 亮度 -> 限幅与文字覆盖。
// 颜色控制contrast=128/brightness=0为单位映射。坐标/DE/同步和叠加配置与像素逐拍对齐。
module video_pixel_pipeline(
    input wire clk,rst,de_in,hs_in,vs_in,
    input wire [10:0] x_in,y_in,
    input wire [23:0] rgb0,rgb1,
    input wire scene_valid_in,
    input wire [7:0] scene_token_in,
    output reg scene_valid_out,
    output reg [7:0] scene_token_out,
    input wire [7:0] alpha,contrast,
    input wire signed [8:0] brightness,
    input wire osd_enable,subtitle_enable,
    input wire [31:0] osd_value,
    input wire [127:0] subtitle_text,
    input wire [10:0] subtitle_shift,
    input wire [23:0] osd_color,subtitle_color,
    output reg de_out,hs_out,vs_out,
    output reg [10:0] x_out,y_out,
    output reg [23:0] rgb_out
);
    reg [15:0] product0[0:2],product1[0:2];
    reg [16:0] sum[0:2];
    reg signed [18:0] gain_product[0:2];
    reg signed [11:0] adjusted[0:2];
    reg [10:0] px[0:3],py[0:3];
    reg [3:0] pd,ph,pv,text_hit;
    reg [3:0] scene_valid_pipe;
    reg [7:0] scene_token_pipe[0:3];
    reg [23:0] text_color[0:3];
    reg [7:0] contrast0,contrast1;
    reg signed [8:0] bright0,bright1,bright2;
    reg [11:0] scroll_sum0;
    wire [11:0] scroll_x=scroll_sum0>=1408?scroll_sum0-12'd1408:scroll_sum0;
    wire osd_window=osd_enable && x_in<64 && y_in<8;
    reg osd_window0,sub_line0,text_window1;
    reg [7:0] osd_character0,character1;
    reg [127:0] subtitle_text0;
    reg [2:0] row0,column0,row1,column1;
    reg [23:0] osd_color0,subtitle_color0;
    wire [3:0] hex_digit=osd_value[(7-x_in[5:3])*4+:4];
    wire [7:0] bitmap;
    wire glyph=bitmap[7-column1];
    font8x7 font(.character(character1),.row(row1),.bitmap(bitmap));
    integer i;
    function signed [9:0] center(input [16:0] weighted);
        reg [16:0] rounded;
        begin rounded=weighted+(weighted>>8);center=$signed({1'b0,rounded[15:8]})-10'sd128;end
    endfunction
    function [7:0] clamp(input signed [11:0] value);
        begin clamp=value<0?0:(value>255?255:value[7:0]);end
    endfunction
    always @(posedge clk or posedge rst)begin
        if(rst)begin
            de_out<=0;hs_out<=0;vs_out<=0;x_out<=0;y_out<=0;rgb_out<=0;
            pd<=0;ph<=0;pv<=0;text_hit<=0;scene_valid_pipe<=0;scene_valid_out<=0;scene_token_out<=0;
            contrast0<=128;contrast1<=128;bright0<=0;bright1<=0;bright2<=0;
            scroll_sum0<=0;osd_window0<=0;sub_line0<=0;text_window1<=0;osd_character0<=0;character1<=0;
            subtitle_text0<=0;row0<=0;column0<=0;row1<=0;column1<=0;osd_color0<=0;subtitle_color0<=0;
            for(i=0;i<4;i=i+1)begin px[i]<=0;py[i]<=0;text_color[i]<=0;scene_token_pipe[i]<=0;end
            for(i=0;i<3;i=i+1)begin product0[i]<=0;product1[i]<=0;sum[i]<=0;gain_product[i]<=0;adjusted[i]<=0;end
        end else begin
            px[0]<=x_in;py[0]<=y_in;pd<={pd[2:0],de_in};ph<={ph[2:0],hs_in};pv<={pv[2:0],vs_in};
            scene_valid_pipe<={scene_valid_pipe[2:0],scene_valid_in};scene_token_pipe[0]<=scene_token_in;
            // 与五拍颜色流水对齐：先坐标相加，再字符选择，最后查字模。
            scroll_sum0<={1'b0,x_in}+{1'b0,subtitle_shift};osd_window0<=osd_window;
            sub_line0<=subtitle_enable && y_in>=680 && y_in<688;
            osd_character0<=hex_digit<10?8'h30+hex_digit:8'h41+hex_digit-10;
            subtitle_text0<=subtitle_text;row0<=y_in[2:0];column0<=x_in[2:0];
            osd_color0<=osd_color;subtitle_color0<=subtitle_color;
            character1<=osd_window0?osd_character0:subtitle_text0[scroll_x[6:3]*8+:8];
            row1<=row0;column1<=osd_window0?column0:scroll_x[2:0];
            text_window1<=osd_window0 || (sub_line0 && scroll_x<128);
            text_hit<={text_hit[2],text_window1 && glyph,2'b00};
            text_color[1]<=osd_window0?osd_color0:subtitle_color0;
            for(i=1;i<4;i=i+1)begin px[i]<=px[i-1];py[i]<=py[i-1];scene_token_pipe[i]<=scene_token_pipe[i-1];end
            text_color[2]<=text_color[1];text_color[3]<=text_color[2];
            contrast0<=contrast;contrast1<=contrast0;bright0<=brightness;bright1<=bright0;bright2<=bright1;
            for(i=0;i<3;i=i+1)begin
                product0[i]<=rgb0[i*8+:8]*(8'hff-alpha);product1[i]<=rgb1[i*8+:8]*alpha;
                sum[i]<={1'b0,product0[i]}+{1'b0,product1[i]}+17'd128;
                gain_product[i]<=center(sum[i])*$signed({1'b0,contrast1});
                adjusted[i]<=12'sd128+(gain_product[i]>>>7)+bright2;
            end
            x_out<=px[3];y_out<=py[3];de_out<=pd[3];hs_out<=ph[3];vs_out<=pv[3];
            scene_valid_out<=scene_valid_pipe[3];scene_token_out<=scene_token_pipe[3];
            if(!pd[3])rgb_out<=0;
            else if(text_hit[3])rgb_out<=text_color[3];
            else rgb_out<={clamp(adjusted[2]),clamp(adjusted[1]),clamp(adjusted[0])};
        end
    end
endmodule
