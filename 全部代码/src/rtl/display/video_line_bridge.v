`timescale 1ns/1ps
// APUG092整行连续输入桥。缓存完整行后才启动传输，SOF/EOL与RGB同拍，ready低时保持。
// fault要求上层停止并reset重同步，不能静默覆盖buffer或丢像素。
module video_line_bridge #(
    parameter integer WIDTH=1280,HEIGHT=720,BUFFER_BITS=12
)(
    input wire clk,rst,pixel_valid,
    input wire [23:0] pixel_rgb,
    input wire [10:0] x,y,
    input wire scene_valid,
    input wire [7:0] scene_token,
    input wire axis_ready,
    output reg axis_valid,axis_eol,
    output wire axis_sof,
    output wire [23:0] axis_rgb,
    output wire axis_scene_valid,
    output wire [7:0] axis_scene_token,
    output reg fault,
    output reg [1:0] fault_code,
    output reg [BUFFER_BITS:0] queued_words
);
    localparam DEPTH=1<<BUFFER_BITS;
    // SWUG106支持bram_32k；场景标签与RGB同存，资源以当前完整构建为准。
    (* ram_style="bram_32k" *) reg [33:0] memory[0:DEPTH-1];
    reg [33:0] output_word;
    reg [BUFFER_BITS-1:0] wr_ptr,rd_ptr;
    reg [10:0] expected_x,expected_y,issue_x;
    reg [BUFFER_BITS:0] complete_lines;
    reg sending,issued_all,waiting_sof;
    wire fetch=sending && !issued_all && (!axis_valid || axis_ready) && !fault;
    wire input_ok=waiting_sof?(x==0 && y==0):(x==expected_x && y==expected_y);
    // 协议Core仍在复位/相位对齐时不接收首帧，等待下一帧可避免小行缓存提前溢出。
    wire start_armed=!waiting_sof || axis_ready;
    wire write_take=pixel_valid && !fault && input_ok && start_armed && (queued_words<DEPTH || fetch);
    wire line_arrives=write_take && x==WIDTH-1;
    wire line_leaves=axis_valid && axis_ready && axis_eol;
    wire coordinate_error=pixel_valid && !fault && !waiting_sof && !input_ok;
    wire overflow_error=pixel_valid && !fault && !waiting_sof && input_ok && queued_words==DEPTH && !fetch;
    assign axis_rgb=output_word[23:0];
    assign axis_sof=axis_valid && output_word[24];
    assign axis_scene_valid=output_word[33];assign axis_scene_token=output_word[32:25];
    always @(posedge clk)begin
        if(write_take)memory[wr_ptr]<={scene_valid,scene_token,x==0 && y==0,pixel_rgb};
        if(fetch)output_word<=memory[rd_ptr];
    end
    always @(posedge clk or posedge rst)begin
        if(rst)begin
            wr_ptr<=0;rd_ptr<=0;expected_x<=0;expected_y<=0;issue_x<=0;complete_lines<=0;
            sending<=0;issued_all<=0;waiting_sof<=1;axis_valid<=0;axis_eol<=0;fault<=0;fault_code<=0;queued_words<=0;
        end else begin
            // 保存首次错误，停止接收后的后续坐标不能覆盖原始原因。
            if(coordinate_error)begin fault<=1;fault_code<=2'd1;end
            else if(overflow_error)begin fault<=1;fault_code<=2'd2;end
            case({write_take,fetch})
                2'b10:queued_words<=queued_words+1'b1;
                2'b01:queued_words<=queued_words-1'b1;
            endcase
            case({line_arrives,line_leaves})
                2'b10:complete_lines<=complete_lines+1'b1;
                2'b01:complete_lines<=complete_lines-1'b1;
            endcase
            if(write_take)begin
                waiting_sof<=0;
                wr_ptr<=wr_ptr+1'b1;
                if(x==WIDTH-1)begin expected_x<=0;expected_y<=y==HEIGHT-1?0:expected_y+1'b1;end
                else expected_x<=expected_x+1'b1;
            end
            if(!sending && complete_lines!=0 && axis_ready && !fault)begin sending<=1;issued_all<=0;issue_x<=0;end
            if(axis_valid && axis_ready)begin axis_valid<=0;axis_eol<=0;end
            if(fetch)begin
                rd_ptr<=rd_ptr+1'b1;axis_valid<=1;axis_eol<=issue_x==WIDTH-1;
                if(issue_x==WIDTH-1)issued_all<=1;else issue_x<=issue_x+1'b1;
            end
            if(line_leaves)begin sending<=0;issued_all<=0;end
        end
    end
endmodule
