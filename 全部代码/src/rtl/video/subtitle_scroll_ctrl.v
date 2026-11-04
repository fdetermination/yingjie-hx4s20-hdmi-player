`timescale 1ns/1ps
// 128像素字幕在1280可视宽度+128间隙循环，所有移动只发生在帧边界。
module subtitle_scroll_ctrl #(parameter integer FRAME_DIV=2)(
    input wire clk,rst,frame_start,enable,restart,
    input wire [3:0] pixels_per_step,
    output reg [10:0] shift
);
    localparam COUNT_BITS=FRAME_DIV<2?1:$clog2(FRAME_DIV);
    reg [COUNT_BITS-1:0] frame_count;
    wire [11:0] next_shift={1'b0,shift}+pixels_per_step;
    always @(posedge clk or posedge rst)begin
        if(rst)begin shift<=0;frame_count<=0;end
        else if(restart)begin shift<=0;frame_count<=0;end
        else if(!enable)frame_count<=0;
        else if(frame_start)begin
            if(frame_count==FRAME_DIV-1)begin
                frame_count<=0;shift<=next_shift>=1408?next_shift-1408:next_shift;
            end else frame_count<=frame_count+1'b1;
        end
    end
endmodule
