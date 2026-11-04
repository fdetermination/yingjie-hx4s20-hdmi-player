`timescale 1ns/1ps
// 自主 RIFF/WAVE chunk 流解析：48kHz PCM16 双声道，直接输出 PCM 帧。
module wav_stream_decoder (
    input wire clk,rst,start,abort,
    input wire [31:0] file_size,
    input wire in_valid,
    output wire in_ready,
    input wire [7:0] in_data,
    input wire in_last,
    output reg pcm_valid,
    input wire pcm_ready,
    output reg signed [15:0] pcm_left,pcm_right,
    output wire busy,
    output reg done,error,
    output reg [3:0] error_code
);
    localparam IDLE=0,RIFF=1,RIFF_CHECK=2,CHUNK=3,CHUNK_CHECK=4,
        FORMAT=5,FORMAT_CHECK=6,SAMPLES=7,SKIP=8,PAD=9,NEXT=10,
        TAIL=11,FLUSH=12,FINISHED=13,FAILED=14,CHUNK_RANGE=15,NEXT_RANGE=16;
    reg [4:0] state;
    // RIFF头验收后，复用同一完整32bit尺寸寄存器接收后续chunk尺寸。
    reg [31:0] size_field;
    wire [31:0] declared_riff=size_field,chunk_size=size_field;
    reg riff_bad,fmt_bad,chunk_is_fmt,chunk_is_data;
    wire riff_size_bad=chunk_is_fmt;
    reg [31:0] bytes_left,riff_left,remaining;
    reg [4:0] index;
    reg odd,fmt_seen,data_seen,eof_seen;
    reg [1:0] phase;
    reg [23:0] sample_bytes;
    reg [32:0] chunk_end;
    reg [31:0] riff_limit;
    function [7:0] riff_byte(input [2:0] offset);
        begin case(offset)
            0:riff_byte=8'h52;1:riff_byte=8'h49;2,3:riff_byte=8'h46;
            4:riff_byte=8'h57;5:riff_byte=8'h41;6:riff_byte=8'h56;7:riff_byte=8'h45;
            default:riff_byte=0;
        endcase end
    endfunction
    function [15:0] chunk_bytes(input [1:0] offset);
        begin case(offset)
            0:chunk_bytes=16'h6664;1:chunk_bytes=16'h6d61;
            2:chunk_bytes=16'h7474;3:chunk_bytes=16'h2061;
        endcase end
    endfunction
    function [7:0] format_byte(input [3:0] offset);
        begin case(offset)
            0:format_byte=1;2,10:format_byte=2;4:format_byte=8'h80;
            5:format_byte=8'hbb;9:format_byte=8'hee;12:format_byte=4;14:format_byte=16;
            default:format_byte=0;
        endcase end
    endfunction
    wire [15:0] expected_chunk=chunk_bytes(index[1:0]);
    assign busy=!(state==IDLE || state==FINISHED || state==FAILED);
    assign in_ready=!eof_seen && (!pcm_valid || pcm_ready) &&
        (state==RIFF || state==CHUNK || state==FORMAT || state==SAMPLES || state==SKIP || state==PAD || state==TAIL);

    task fail;
        input [3:0] code;
        // 已发布的样本保持到 ready 或显式 abort，错误不能悄悄撤回 valid。
        begin state<=FAILED; error<=1; error_code<=code; end
    endtask
    always @(posedge clk or posedge rst) begin
        if(rst) begin
            state<=IDLE; bytes_left<=0; riff_left<=0; remaining<=0; index<=0;
            odd<=0; fmt_seen<=0; data_seen<=0; eof_seen<=0; phase<=0; sample_bytes<=0;
            pcm_valid<=0; pcm_left<=0; pcm_right<=0; done<=0; error<=0; error_code<=0;
            chunk_end<=0; riff_limit<=0;
            riff_bad<=0;fmt_bad<=0;chunk_is_fmt<=0;chunk_is_data<=0;
        end else if(abort) begin
            state<=IDLE; pcm_valid<=0; done<=0; error<=0; error_code<=0; eof_seen<=0;
        end else if(start && !busy) begin
            state<=RIFF; bytes_left<=file_size; index<=0; remaining<=0;
            riff_limit<=file_size-32'd8;
            fmt_seen<=0; data_seen<=0; eof_seen<=0; phase<=0;
            pcm_valid<=0; done<=0; error<=0; error_code<=0;
            riff_bad<=0;fmt_bad<=0;chunk_is_fmt<=0;chunk_is_data<=0;
            if(file_size<12) fail(1);
        end else begin
            if(pcm_valid && pcm_ready) pcm_valid<=0;
            case(state)
                RIFF_CHECK: begin
                    if(riff_bad) fail(2);
                    else if(riff_size_bad) fail(3);
                    else begin riff_left<=declared_riff-32'd4;state<=NEXT;end
                end
                CHUNK_CHECK: begin
                    chunk_end<={1'b0,chunk_size}+chunk_size[0];
                    state<=CHUNK_RANGE;
                end
                CHUNK_RANGE: begin
                    if(chunk_end>{1'b0,riff_left}) fail(3);
                    else begin
                        remaining<=chunk_size; odd<=chunk_size[0]; index<=0;
                        if(chunk_is_fmt) begin
                            if(fmt_seen || data_seen || chunk_size<16) fail(4);
                            else begin fmt_bad<=0;state<=FORMAT;end
                        end else if(chunk_is_data) begin
                            if(!fmt_seen || data_seen || chunk_size==0 || chunk_size[1:0]!=0) fail(5);
                            else begin data_seen<=1; phase<=0; state<=SAMPLES; end
                        end else state<=(chunk_size==0)?NEXT:SKIP;
                    end
                end
                FORMAT_CHECK: begin
                    if(fmt_bad) fail(6);
                    else begin fmt_seen<=1; state<=odd?PAD:NEXT; end
                end
                NEXT: state<=NEXT_RANGE;
                NEXT_RANGE: begin
                    if(riff_left==0) begin
                        if(!data_seen) fail(5);
                        else state<=(bytes_left==0)?FLUSH:TAIL;
                    end else if(riff_left<8) fail(3);
                    else begin index<=0; state<=CHUNK; end
                end
                FLUSH: if(!pcm_valid || pcm_ready) begin state<=FINISHED; done<=1; end
            endcase
            if(in_valid && in_ready) begin
                bytes_left<=bytes_left-1'b1;
                if(state!=RIFF && state!=TAIL)riff_left<=riff_left-1'b1;
                case(state)
                    RIFF: begin
                        if(index[3:2]!=2'b01)riff_bad<=riff_bad || in_data!=riff_byte({index[3],index[1:0]});
                        else size_field<={in_data,size_field[31:8]};
                        // 尺寸在字节7已完整；复用尚未参与chunk分类的标志提前验收。
                        if(index==8)chunk_is_fmt<=declared_riff<4 || declared_riff>riff_limit;
                        if(index==11)state<=RIFF_CHECK;else index<=index+1'b1;
                    end
                    CHUNK: begin
                        if(!index[2])begin
                            if(index[1:0]==0)begin
                                chunk_is_fmt<=in_data==expected_chunk[15:8];
                                chunk_is_data<=in_data==expected_chunk[7:0];
                            end else begin
                                chunk_is_fmt<=chunk_is_fmt && in_data==expected_chunk[15:8];
                                chunk_is_data<=chunk_is_data && in_data==expected_chunk[7:0];
                            end
                        end else size_field<={in_data,size_field[31:8]};
                        if(index==7) state<=CHUNK_CHECK; else index<=index+1'b1;
                    end
                    FORMAT: begin
                        if(index<16) begin fmt_bad<=fmt_bad || in_data!=format_byte(index[3:0]); index<=index+1'b1; end
                        remaining<=remaining-1'b1;
                        if(remaining==1) state<=FORMAT_CHECK;
                    end
                    SAMPLES: begin
                        remaining<=remaining-1'b1;
                        case(phase)
                            0: sample_bytes[7:0]<=in_data;
                            1: sample_bytes[15:8]<=in_data;
                            2: sample_bytes[23:16]<=in_data;
                            3: begin pcm_left<=sample_bytes[15:0]; pcm_right<={in_data,sample_bytes[23:16]}; pcm_valid<=1; end
                        endcase
                        phase<=phase+1'b1;
                        if(remaining==1) state<=NEXT;
                    end
                    SKIP: begin remaining<=remaining-1'b1; if(remaining==1) state<=odd?PAD:NEXT; end
                    PAD: state<=NEXT;
                    TAIL: if(in_last) state<=FLUSH;
                endcase
                if(in_last) begin
                    eof_seen<=1;
                    if(bytes_left!=1) fail(7);
                end else if(bytes_left<=1) fail(7);
            end
        end
    end
endmodule
