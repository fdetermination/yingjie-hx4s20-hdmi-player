`timescale 1ns/1ps
// WAV写域 -> 双时钟FIFO -> 同步读结果保持 -> 精确48kHz采样。
// 停止消费保留下一样本；新曲目通过共同reset排空两域，不能仅清一个指针。
module pcm_audio_stream #(
    parameter integer CLK_HZ=74250000,SAMPLE_HZ=48000,FIFO_BITS=10
)(
    input wire wr_clk,clk,rst,enable,
    input wire pcm_valid,
    output wire pcm_ready,
    input wire signed [15:0] pcm_left,pcm_right,
    output wire sample_valid,
    output wire signed [15:0] sample_left,sample_right,
    output wire [31:0] sample_count,
    output wire underflow
);
    wire fifo_empty,fifo_valid,consume;
    wire signed [15:0] fifo_left,fifo_right;
    reg pending,held_valid;
    reg signed [15:0] held_left,held_right;
    wire read_enable=!rst && !pending && (!held_valid || consume) && !fifo_empty;
    pcm_async_fifo #(.ADDR_BITS(FIFO_BITS)) fifo(
        .wr_clk(wr_clk),.rd_clk(clk),.rst(rst),.wr_valid(pcm_valid),.wr_ready(pcm_ready),
        .wr_left(pcm_left),.wr_right(pcm_right),.rd_en(read_enable),.rd_empty(fifo_empty),
        .rd_valid(fifo_valid),.rd_left(fifo_left),.rd_right(fifo_right));
    pcm_playback_engine #(.CLK_HZ(CLK_HZ),.SAMPLE_HZ(SAMPLE_HZ)) player(
        .clk(clk),.rst(rst),.enable(enable),.pcm_valid(held_valid),.pcm_ready(consume),
        .pcm_left(held_left),.pcm_right(held_right),.sample_valid(sample_valid),
        .sample_left(sample_left),.sample_right(sample_right),.sample_count(sample_count),.underflow(underflow));
    always @(posedge clk or posedge rst)begin
        if(rst)begin pending<=0;held_valid<=0;held_left<=0;held_right<=0;end
        else begin
            if(consume)held_valid<=0;
            if(read_enable)pending<=1;
            if(fifo_valid)begin held_left<=fifo_left;held_right<=fifo_right;held_valid<=1;pending<=0;end
        end
    end
endmodule
