`timescale 1ns/1ps
// 已对齐像素上的状态/设置文字与八频点柱状图；输出整体增加三拍。
module video_hud #(
    parameter integer SPECTRUM_VISUAL_ENABLE=0,
    parameter integer HUD_ANIMATION_ENABLE=0,
    parameter integer HUD_PEAK_ENABLE=0,
    parameter integer HUD_STYLE_ENABLE=1,
    parameter integer HUD_LABEL_ENABLE=0
)(
    input wire clk,rst,frame_start,bins_valid,
    input wire [127:0] levels,
    input wire de_in,hs_in,vs_in,
    input wire [10:0] x_in,y_in,
    input wire [23:0] rgb_in,
    input wire scene_valid_in,
    input wire [7:0] scene_token_in,
    output reg scene_valid_out,
    output reg [7:0] scene_token_out,
    input wire osd_enable,spectrum_enable,menu_open,
    input wire [15:0] playback_status,
    input wire [2:0] menu_item,
    input wire [1:0] interval_sel,
    input wire signed [8:0] brightness,
    input wire [7:0] contrast,
    input wire subtitle_enable,
    output reg de_out,hs_out,vs_out,
    output reg [10:0] x_out,y_out,
    output reg [23:0] rgb_out
);
    reg [127:0] pending_levels,frame_levels;
    wire text_window=osd_enable && x_in>=16 && x_in<528 &&
        ((y_in>=16 && y_in<32) || (menu_open && y_in>=40 && y_in<56));
    wire spectrum_window=spectrum_enable && x_in>=992 && x_in<1248 && y_in>=520 &&
        y_in<(SPECTRUM_VISUAL_ENABLE?668:656);
    wire [10:0] text_x=x_in-11'd16,band_x=x_in-11'd992;
    wire [10:0] label_x=band_x-11'd4;
    wire [15:0] band_level=frame_levels[band_x[7:5]*16+:16];
    reg [7:0] smoothed_height[0:7],peak_height_state[0:7];
    reg [3:0] peak_hold[0:7];
    integer spectrum_index;
    wire [7:0] bar_height=SPECTRUM_VISUAL_ENABLE && HUD_ANIMATION_ENABLE?smoothed_height[band_x[7:5]]:height(band_level);
    wire [7:0] peak_height=peak_height_state[band_x[7:5]];
    wire [10:0] peak_y=11'd654-{3'b0,peak_height};
    wire bar_x=SPECTRUM_VISUAL_ENABLE?(band_x[4:0]>=4 && band_x[4:0]<28):
        (band_x[4:0]>=2 && band_x[4:0]<18);
    wire bar=bar_x && y_in>=11'd654-bar_height && y_in<654 &&
        (!SPECTRUM_VISUAL_ENABLE || !HUD_STYLE_ENABLE || y_in[2:0]<6);
    wire peak_mark=SPECTRUM_VISUAL_ENABLE && HUD_PEAK_ENABLE && peak_height!=0 && band_x[4:0]>=4 && band_x[4:0]<28 &&
        y_in>=peak_y && y_in<peak_y+11'd2;
    wire spectrum_grid=SPECTRUM_VISUAL_ENABLE && HUD_STYLE_ENABLE && x_in>=996 && x_in<1244 &&
        (y_in==526 || y_in==558 || y_in==590 || y_in==622);
    wire spectrum_border=SPECTRUM_VISUAL_ENABLE && HUD_STYLE_ENABLE &&
        (x_in==992 || x_in==1247 || y_in==520 || y_in==667);
    wire frequency_label_window=SPECTRUM_VISUAL_ENABLE && HUD_LABEL_ENABLE && spectrum_enable &&
        x_in>=996 && x_in<1244 && y_in>=658 && y_in<665;
    wire [1:0] spectrum_bar_zone=y_in<566?2'd2:(y_in<614?2'd1:2'd0);
    reg [255:0] status_text,setting_text;
    reg [255:0] status_text_next,setting_text_next;
    wire [255:0] line_text=y_in<32?status_text:setting_text;
    wire [7:0] character=frequency_label_window?label_character(label_x[7:5],label_x[4:3]):
        line_text[255-text_x[8:4]*8-:8];
    wire [7:0] glyph;
    reg [8:0] magnitude;
    wire [23:0] brightness_digits,contrast_digits;
    reg [7:0] character0;
    reg [2:0] glyph_row0,glyph_column0;
    reg text_window0,spectrum_window0,bar0,menu0;
    reg peak0,grid0,border0,frequency_label0;
    reg [1:0] bar_zone0,bar_zone1;
    reg de0,hs0,vs0;reg [10:0] x0,y0;reg [23:0] rgb0;
    reg de1,hs1,vs1,glyph_hit1,text_window1,spectrum_window1,bar1,menu1;
    reg peak1,grid1,border1,frequency_label1;
    reg [10:0] x1,y1;reg [23:0] rgb1;
    reg scene_valid0,scene_valid1;
    reg [7:0] scene_token0,scene_token1;
    wire [10:0] text_y=y_in<32?y_in-11'd16:y_in-11'd40;
    wire [7:0] period_char=interval_sel==0?"1":(interval_sel==1?"3":"5");
    function [7:0] label_character(input [2:0] band,input [1:0] column);
        begin
            label_character=" ";
            case(band)
                0:case(column)0:label_character="1";1:label_character="8";2:label_character="7";default:begin end endcase
                1:case(column)0:label_character="3";1:label_character="7";2:label_character="5";default:begin end endcase
                2:case(column)0:label_character="7";1:label_character="5";2:label_character="0";default:begin end endcase
                3:case(column)0:label_character="1";1:label_character=".";2:label_character="5";3:label_character="K";endcase
                4:case(column)0:label_character="3";1:label_character="K";default:begin end endcase
                5:case(column)0:label_character="4";1:label_character=".";2:label_character="5";3:label_character="K";endcase
                6:case(column)0:label_character="6";1:label_character="K";default:begin end endcase
                7:case(column)0:label_character="9";1:label_character="K";default:begin end endcase
                default:begin end
            endcase
        end
    endfunction
    function [7:0] hex_char(input [3:0] digit);
        begin hex_char=digit<10?8'd48+digit:8'd65+digit-10;end
    endfunction
    function [7:0] height(input [15:0] value);
        integer bit_index;
        begin
            height=0;
            for(bit_index=0;bit_index<16;bit_index=bit_index+1)
                if(value[bit_index])height=(bit_index+1)*8;
        end
    endfunction
    function [7:0] slew_height(input [7:0] current,input [7:0] target);
        begin
            if(target>current)slew_height=target;
            else if(current>2)slew_height=current-2;
            else slew_height=0;
        end
    endfunction
    wire [7:0] target_height[0:7],next_height[0:7];
    genvar spectrum_bin_index;
    generate for(spectrum_bin_index=0;spectrum_bin_index<8;spectrum_bin_index=spectrum_bin_index+1)begin:height_decode
        assign target_height[spectrum_bin_index]=height(pending_levels[spectrum_bin_index*16+:16]);
        assign next_height[spectrum_bin_index]=slew_height(smoothed_height[spectrum_bin_index],target_height[spectrum_bin_index]);
    end endgenerate
    always @(posedge clk or posedge rst)begin
        if(rst)begin
            for(spectrum_index=0;spectrum_index<8;spectrum_index=spectrum_index+1)begin
                smoothed_height[spectrum_index]<=0;peak_height_state[spectrum_index]<=0;peak_hold[spectrum_index]<=0;
            end
        end else if(frame_start && SPECTRUM_VISUAL_ENABLE && HUD_ANIMATION_ENABLE)begin
            for(spectrum_index=0;spectrum_index<8;spectrum_index=spectrum_index+1)begin
                if(next_height[spectrum_index]>peak_height_state[spectrum_index])begin
                    peak_height_state[spectrum_index]<=next_height[spectrum_index];peak_hold[spectrum_index]<=4'd12;
                end else if(next_height[spectrum_index]>=peak_height_state[spectrum_index])peak_hold[spectrum_index]<=4'd12;
                else if(peak_hold[spectrum_index]!=0)peak_hold[spectrum_index]<=peak_hold[spectrum_index]-1'b1;
                else if(peak_height_state[spectrum_index]-next_height[spectrum_index]>2)
                    peak_height_state[spectrum_index]<=peak_height_state[spectrum_index]-2;
                else peak_height_state[spectrum_index]<=next_height[spectrum_index];
                smoothed_height[spectrum_index]<=next_height[spectrum_index];
            end
        end
    end
    hud_decimal brightness_format(.clk(clk),.rst(rst),.value(magnitude),.ascii(brightness_digits));
    hud_decimal contrast_format(.clk(clk),.rst(rst),.value({1'b0,contrast}),.ascii(contrast_digits));
    font8x7 font(.character(character0),.row(glyph_row0),.bitmap(glyph));
    always @(*)begin
        status_text_next={"YINGJIE ",playback_status[4]?"AUTO":"MAN "," ",
            period_char,"S IMG ",hex_char(playback_status[11:8]),
            " ERR ",hex_char(playback_status[15:12]),"     "};
        setting_text_next="                                ";
        case(menu_item)
            0:setting_text_next={"INTERVAL ",period_char,"S                     "};
            1:setting_text_next={"BRIGHTNESS ",brightness<0?8'h2d:8'h20,brightness_digits,"                 "};
            2:setting_text_next={"CONTRAST ",contrast_digits,"                    "};
            3:setting_text_next=subtitle_enable?"SUBTITLE ON                     ":"SUBTITLE OFF                    ";
            4:setting_text_next=spectrum_enable?"SPECTRUM ON                     ":"SPECTRUM OFF                    ";
        endcase
    end
    always @(posedge clk or posedge rst)begin
        if(rst)begin
            pending_levels<=0;frame_levels<=0;de_out<=0;hs_out<=0;vs_out<=0;x_out<=0;y_out<=0;rgb_out<=0;
            scene_valid0<=0;scene_valid1<=0;scene_valid_out<=0;scene_token0<=0;scene_token1<=0;scene_token_out<=0;
            magnitude<=0;status_text<=0;setting_text<=0;character0<=0;glyph_row0<=0;glyph_column0<=0;
            text_window0<=0;spectrum_window0<=0;bar0<=0;menu0<=0;peak0<=0;grid0<=0;border0<=0;frequency_label0<=0;bar_zone0<=0;bar_zone1<=0;de0<=0;hs0<=0;vs0<=0;x0<=0;y0<=0;rgb0<=0;
            de1<=0;hs1<=0;vs1<=0;glyph_hit1<=0;text_window1<=0;spectrum_window1<=0;bar1<=0;menu1<=0;peak1<=0;grid1<=0;border1<=0;frequency_label1<=0;x1<=0;y1<=0;rgb1<=0;
        end else begin
            if(bins_valid)pending_levels<=levels;
            // 同拍新频点留至下一帧，完整快照避免柱高在帧中跳变。
            if(frame_start)frame_levels<=pending_levels;
            magnitude<=brightness<0?-brightness:brightness;
            status_text<=status_text_next;setting_text<=setting_text_next;
            character0<=character;glyph_row0<=frequency_label_window?(y_in-11'd658):text_y[3:1];glyph_column0<=frequency_label_window?label_x[2:0]:text_x[3:1];
            text_window0<=text_window;spectrum_window0<=spectrum_window;bar0<=bar;menu0<=menu_open;peak0<=peak_mark;grid0<=spectrum_grid;border0<=spectrum_border;frequency_label0<=frequency_label_window;bar_zone0<=spectrum_bar_zone;
            de0<=de_in;hs0<=hs_in;vs0<=vs_in;x0<=x_in;y0<=y_in;rgb0<=rgb_in;
            scene_valid0<=scene_valid_in;scene_token0<=scene_token_in;
            glyph_hit1<=glyph[7-glyph_column0];text_window1<=text_window0;spectrum_window1<=spectrum_window0;bar1<=bar0;menu1<=menu0;peak1<=peak0;grid1<=grid0;border1<=border0;frequency_label1<=frequency_label0;bar_zone1<=bar_zone0;
            de1<=de0;hs1<=hs0;vs1<=vs0;x1<=x0;y1<=y0;rgb1<=rgb0;
            scene_valid1<=scene_valid0;scene_token1<=scene_token0;
            de_out<=de1;hs_out<=hs1;vs_out<=vs1;x_out<=x1;y_out<=y1;
            scene_valid_out<=scene_valid1;scene_token_out<=scene_token1;
            if(!de1)rgb_out<=0;
            else if(text_window1)rgb_out<=glyph_hit1?(menu1?24'hffd060:24'hffffff):24'h102030;
            else if(spectrum_window1 && SPECTRUM_VISUAL_ENABLE)begin
                if(border1)rgb_out<=24'h2f6375;
                else if(frequency_label1)rgb_out<=glyph_hit1?24'h9bc4d2:24'h07131c;
                else if(peak1)rgb_out<=24'he8f6ff;
                else if(bar1)begin
                    case(bar_zone1)
                        2'd0:rgb_out<=24'h25c48d;
                        2'd1:rgb_out<=24'hf4c95d;
                        default:rgb_out<=24'hef5b5b;
                    endcase
                end else if(grid1)rgb_out<=24'h17303d;
                else rgb_out<=24'h07131c;
            end else if(spectrum_window1)rgb_out<=bar1?24'h30d0a0:24'h081018;
            else rgb_out<=rgb1;
        end
    end
endmodule
