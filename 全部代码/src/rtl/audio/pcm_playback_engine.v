`timescale 1ns/1ps
// 有理数相位累加精确采样：每CLK_HZ时钟产生SAMPLE_HZ次采样，无二进制NCO量化漂移。
module pcm_playback_engine #(
    parameter integer CLK_HZ=74250000,SAMPLE_HZ=48000
)(
    input wire clk,rst,enable,
    input wire pcm_valid,
    output wire pcm_ready,
    input wire signed [15:0] pcm_left,pcm_right,
    output reg sample_valid,
    output reg signed [15:0] sample_left,sample_right,
    output reg [31:0] sample_count,
    output reg underflow
);
    localparam PHASE_BITS=$clog2(CLK_HZ+SAMPLE_HZ);
    reg [PHASE_BITS-1:0] phase;
    wire [PHASE_BITS:0] phase_sum={1'b0,phase}+SAMPLE_HZ;
    wire sample_tick=phase_sum>=CLK_HZ;
    assign pcm_ready=!rst && enable && sample_tick;
    always @(posedge clk or posedge rst)begin
        if(rst)begin phase<=0;sample_valid<=0;sample_left<=0;sample_right<=0;sample_count<=0;underflow<=0;end
        else begin
            if(enable)phase<=sample_tick?phase_sum-CLK_HZ:phase_sum;
            else phase<=0;
            sample_valid<=0;
            if(enable && sample_tick)begin
                sample_valid<=1;sample_count<=sample_count+1'b1;
                if(pcm_valid)begin sample_left<=pcm_left;sample_right<=pcm_right;end
                else begin sample_left<=0;sample_right<=0;underflow<=1;end
            end
        end
    end
endmodule
