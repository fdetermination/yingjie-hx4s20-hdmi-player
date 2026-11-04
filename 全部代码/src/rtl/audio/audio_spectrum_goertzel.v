`timescale 1ns/1ps
// 256点8频点Goertzel；有符号PCM直接参与递推，一组乘法器按时分处理全部频点。
// levels每16bit为频点功率/2^29，k=1,2,4,8,16,24,32,48。最坏145clk以内/样本。
module audio_spectrum_goertzel(
    input wire clk,rst,
    input wire sample_valid,
    input wire signed [15:0] sample_left,sample_right,
    output wire sample_ready,
    output reg overrun,
    output reg bins_valid,
    output reg [127:0] levels
);
    localparam IDLE=0,LOAD=1,REC_FEED=2,REC_WAIT=3,REC_USE=4,UPDATE=5,
        SQ1_WAIT=6,SQ1_USE=7,SQ2_WAIT=8,SQ2_USE=9,CROSS1_WAIT=10,CROSS1_USE=11,
        CROSS2_WAIT=12,PUBLISH=13,NEXT_BIN=14,S1_HIGH=15,S2_LOW=16,S2_HIGH=17,
        READ_DONE=18,WRITE_S1_HIGH=19,WRITE_S2_LOW=20,WRITE_S2_HIGH=21;
    reg [4:0] state;
    reg [2:0] band;
    reg [7:0] sample_index;
    reg last_sample;
    (* ram_style="bram" *) reg [15:0] history[0:31];
    reg [15:0] history_word;
    reg signed [31:0] previous1,previous2,coefficient,next_value,sample_value;
    reg signed [31:0] mul_a,mul_b;
    reg signed [63:0] product,square_sum;
    reg [127:0] work_levels;
    wire signed [16:0] stereo_sum=$signed({sample_left[15],sample_left})+$signed({sample_right[15],sample_right});
    wire signed [63:0] final_power=square_sum-product;
    wire history_read=!rst && ((state==LOAD && sample_index!=0) || state==S1_HIGH || state==S2_LOW || state==S2_HIGH);
    wire [1:0] read_half=state==S1_HIGH?2'b01:state==S2_LOW?2'b10:state==S2_HIGH?2'b11:2'b00;
    wire history_write=!rst && ((state==UPDATE && !last_sample) || state==WRITE_S1_HIGH || state==WRITE_S2_LOW || state==WRITE_S2_HIGH);
    wire [1:0] write_half=state==WRITE_S1_HIGH?2'b01:state==WRITE_S2_LOW?2'b10:state==WRITE_S2_HIGH?2'b11:2'b00;
    wire [15:0] history_data=state==WRITE_S1_HIGH?next_value[31:16]:state==WRITE_S2_LOW?previous1[15:0]:
        state==WRITE_S2_HIGH?previous1[31:16]:next_value[15:0];
    function signed [31:0] coeff(input [2:0] index);
        begin case(index)
            0:coeff=2096520;1:coeff=2094626;2:coeff=2087054;3:coeff=2056856;
            4:coeff=1937516;5:coeff=1743718;6:coeff=1482910;7:coeff=802545;
        endcase end
    endfunction
    assign sample_ready=state==IDLE && !rst;
    // 每窗口首样本从零递推，其余样本才读取RAM；复位或窗口结束无需清扫存储。
    always @(posedge clk)begin
        if(history_read)history_word<=history[{band,read_half}];
        if(history_write)history[{band,write_half}]<=history_data;
    end
    // 唯一乘法表达式；每次先设置操作数，再等待寄存乘积，避免组合乘法链。
    always @(posedge clk)product<=mul_a*mul_b;
    always @(posedge clk or posedge rst)begin
        if(rst)begin
            state<=IDLE;band<=0;sample_index<=0;last_sample<=0;overrun<=0;
            bins_valid<=0;levels<=0;work_levels<=0;previous1<=0;previous2<=0;
            coefficient<=0;next_value<=0;sample_value<=0;mul_a<=0;mul_b<=0;square_sum<=0;
        end else begin
            bins_valid<=0;
            if(sample_valid && !sample_ready)overrun<=1;
            case(state)
                IDLE:if(sample_valid)begin
                    sample_value<=stereo_sum>>>1;last_sample<=sample_index==255;band<=0;state<=LOAD;
                end
                LOAD:begin
                    coefficient<=coeff(band);
                    if(sample_index==0)begin previous1<=0;previous2<=0;state<=REC_FEED;end
                    else state<=S1_HIGH;
                end
                S1_HIGH:begin previous1[15:0]<=history_word;state<=S2_LOW;end
                S2_LOW:begin previous1[31:16]<=history_word;state<=S2_HIGH;end
                S2_HIGH:begin previous2[15:0]<=history_word;state<=READ_DONE;end
                READ_DONE:begin previous2[31:16]<=history_word;state<=REC_FEED;end
                REC_FEED:begin mul_a<=previous1;mul_b<=coefficient;state<=REC_WAIT;end
                REC_WAIT:state<=REC_USE;
                REC_USE:begin next_value<=sample_value+(product>>>20)-previous2;state<=UPDATE;end
                UPDATE:if(last_sample)begin mul_a<=next_value;mul_b<=next_value;state<=SQ1_WAIT;end
                       else state<=WRITE_S1_HIGH;
                WRITE_S1_HIGH:state<=WRITE_S2_LOW;
                WRITE_S2_LOW:state<=WRITE_S2_HIGH;
                WRITE_S2_HIGH:state<=NEXT_BIN;
                SQ1_WAIT:state<=SQ1_USE;
                SQ1_USE:begin square_sum<=product;mul_a<=previous1;mul_b<=previous1;state<=SQ2_WAIT;end
                SQ2_WAIT:state<=SQ2_USE;
                SQ2_USE:begin square_sum<=square_sum+product;mul_a<=coefficient;mul_b<=next_value;state<=CROSS1_WAIT;end
                CROSS1_WAIT:state<=CROSS1_USE;
                CROSS1_USE:begin mul_a<=product>>>20;mul_b<=previous1;state<=CROSS2_WAIT;end
                CROSS2_WAIT:state<=PUBLISH;
                PUBLISH:begin
                    if(final_power[63])work_levels<={16'd0,work_levels[127:16]};
                    else if(|final_power[62:45])work_levels<={16'hffff,work_levels[127:16]};
                    else work_levels<={final_power[44:29],work_levels[127:16]};
                    state<=NEXT_BIN;
                end
                NEXT_BIN:if(band==7)begin
                    if(last_sample)begin sample_index<=0;levels<=work_levels;bins_valid<=1;end
                    else sample_index<=sample_index+1'b1;
                    state<=IDLE;
                end else begin band<=band+1'b1;state<=LOAD;end
            endcase
        end
    end
endmodule
