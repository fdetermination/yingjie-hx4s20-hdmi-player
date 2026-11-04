`timescale 1ns/1ps
// CEA 1280x720p60；pixel_clk=74.25MHz。存储故障不得暂停本模块计数。
module video_timing_720p #(
    parameter integer WIDTH=1280,HEIGHT=720,H_FRONT=110,H_SYNC=40,H_BACK=220,
    parameter integer V_FRONT=5,V_SYNC=5,V_BACK=20
)(
    input wire pixel_clk,rst,
    output reg [10:0] x,y,
    output wire de,hsync,vsync,line_start,frame_start,vblank_start
);
    assign de=x<WIDTH && y<HEIGHT;
    assign hsync=x>=WIDTH+H_FRONT && x<WIDTH+H_FRONT+H_SYNC;
    assign vsync=y>=HEIGHT+V_FRONT && y<HEIGHT+V_FRONT+V_SYNC;
    assign line_start=x==0;
    assign frame_start=x==0 && y==0;
    assign vblank_start=x==0 && y==HEIGHT;
    always @(posedge pixel_clk or posedge rst)begin
        if(rst)begin x<=0;y<=0;end
        else if(x==WIDTH+H_FRONT+H_SYNC+H_BACK-1)begin
            x<=0;
            if(y==HEIGHT+V_FRONT+V_SYNC+V_BACK-1)y<=0;else y<=y+1'b1;
        end else x<=x+1'b1;
    end
endmodule
