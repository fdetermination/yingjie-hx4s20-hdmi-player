`timescale 1ns/1ps
// 帧边界启动的16帧淡入淡出；alpha=0显示旧帧，255显示新帧。
module video_transition_ctrl #(
    parameter integer STEPS=16
)(
    input wire clk,rst,
    input wire frame_start,
    input wire start,
    output reg active,
    output reg [7:0] alpha,
    output reg done
);
    reg [7:0] step;
    always @(posedge clk or posedge rst)begin
        if(rst)begin active<=0;alpha<=0;step<=0;done<=0;end
        else begin
            done<=0;
            if(start && !active)begin active<=1;step<=0;alpha<=0;end
            else if(active && frame_start)begin
                if(step>=STEPS-1)begin active<=0;alpha<=8'hff;done<=1;end
                else begin step<=step+1'b1;alpha<=((step+1'b1)*255)/STEPS;end
            end
        end
    end
endmodule
