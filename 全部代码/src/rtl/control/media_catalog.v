`timescale 1ns/1ps
// FAT目录描述符缓存；同8字符主文件名配对，目录顺序决定图片索引。
module media_catalog #(
    parameter integer MAX_IMAGES=4,MAX_AUDIO=4,
    parameter integer INDEX_BITS=(MAX_IMAGES<2)?1:$clog2(MAX_IMAGES)
)(
    input wire clk,rst,scan_start,list_done,list_error,
    input wire entry_valid,
    output wire entry_ready,
    input wire [87:0] entry_name,
    input wire [1:0] entry_kind,
    input wire [27:0] entry_cluster,
    input wire [31:0] entry_size,
    output reg catalog_done,catalog_error,overflow,
    output reg [INDEX_BITS:0] image_count,
    input wire query_valid,
    output wire query_ready,
    input wire [INDEX_BITS-1:0] query_index,
    output reg result_valid,
    input wire result_ready,
    output reg result_found,audio_found,
    output reg [27:0] image_cluster,audio_cluster,
    output reg [31:0] image_size,audio_size
);
    localparam RECORD_BITS=$clog2(MAX_IMAGES+MAX_AUDIO),RAM_BITS=RECORD_BITS+3;
    localparam AUDIO_BITS=$clog2(MAX_AUDIO+1);
    localparam IDLE=0,WRITE=1,IMAGE_FETCH=2,IMAGE_USE=3,AUDIO_FETCH=4,AUDIO_USE=5,
        AUDIO_SELECT=6,AUDIO_META_FETCH=7,AUDIO_META_USE=8;
    reg [3:0] state;
    reg scanning,done_pending,match_name;
    reg [AUDIO_BITS-1:0] audio_count,audio_index;
    reg [RECORD_BITS-1:0] record_address;
    reg [2:0] half_index;
    reg [127:0] write_payload;
    reg [63:0] lookup_name;
    reg [15:0] read_word;
    (* ram_style="bram" *) reg [15:0] records[0:(1<<RAM_BITS)-1];
    function [7:0] normalize_char(input [7:0] c);
        begin normalize_char=(c>=8'h61 && c<=8'h7a)?(c & 8'hdf):c;end
    endfunction
    assign entry_ready=scanning && state==IDLE && !done_pending && !scan_start && !rst;
    assign query_ready=catalog_done && !catalog_error && !scanning && state==IDLE && !result_valid && !scan_start && !rst;
    wire take_entry=entry_valid && entry_ready;
    wire store_entry=take_entry && entry_size!=0 &&
        ((entry_kind==1 && image_count<MAX_IMAGES) || (entry_kind==2 && audio_count<MAX_AUDIO));
    wire excess_entry=take_entry && entry_size!=0 &&
        ((entry_kind==1 && image_count>=MAX_IMAGES) || (entry_kind==2 && audio_count>=MAX_AUDIO));
    wire write_word=state==WRITE && !rst && !scan_start && !list_error;
    wire fetch_word=(state==IMAGE_FETCH || state==AUDIO_FETCH || state==AUDIO_META_FETCH) && !rst && !scan_start;
    wire [15:0] normalized_word={normalize_char(write_payload[15:8]),normalize_char(write_payload[7:0])};
    always @(posedge clk)begin
        if(store_entry && !list_error)write_payload<={entry_size,4'b0,entry_cluster,entry_name[87:24]};
        else if(write_word)write_payload<={16'd0,write_payload[127:16]};
        if(write_word)records[{record_address,half_index}]<=half_index<4?normalized_word:write_payload[15:0];
        if(fetch_word)read_word<=records[{record_address,half_index}];
    end
    always @(posedge clk or posedge rst)begin
        if(rst)begin
            state<=IDLE;scanning<=0;done_pending<=0;match_name<=0;catalog_done<=0;catalog_error<=0;overflow<=0;
            image_count<=0;audio_count<=0;audio_index<=0;record_address<=0;half_index<=0;
            result_valid<=0;result_found<=0;audio_found<=0;image_cluster<=0;image_size<=0;audio_cluster<=0;audio_size<=0;
        end else if(scan_start)begin
            state<=IDLE;scanning<=1;done_pending<=0;catalog_done<=0;catalog_error<=0;overflow<=0;
            image_count<=0;audio_count<=0;result_valid<=0;result_found<=0;audio_found<=0;
        end else if(scanning && list_error)begin
            state<=IDLE;scanning<=0;done_pending<=0;catalog_done<=1;catalog_error<=1;
            image_count<=0;audio_count<=0;result_valid<=0;result_found<=0;audio_found<=0;
            if(excess_entry)overflow<=1;
        end else begin
            if(result_valid && result_ready)result_valid<=0;
            if(scanning && list_done)done_pending<=1;
            if(excess_entry)overflow<=1;
            case(state)
                IDLE:begin
                    if(store_entry)begin
                        record_address<=entry_kind==1?image_count:MAX_IMAGES+audio_count;
                        if(entry_kind==1)image_count<=image_count+1'b1;
                        else audio_count<=audio_count+1'b1;
                        half_index<=0;state<=WRITE;
                    end else if(scanning && (list_done || done_pending))begin
                        scanning<=0;done_pending<=0;catalog_done<=1;
                    end else if(query_valid && query_ready)begin
                        result_found<=query_index<image_count;audio_found<=0;
                        image_cluster<=0;image_size<=0;audio_cluster<=0;audio_size<=0;
                        if(query_index>=image_count)result_valid<=1;
                        else begin record_address<=query_index;half_index<=0;state<=IMAGE_FETCH;end
                    end
                end
                WRITE:if(half_index==7)state<=IDLE;else half_index<=half_index+1'b1;
                IMAGE_FETCH:state<=IMAGE_USE;
                IMAGE_USE:begin
                    if(half_index<4)lookup_name<={read_word,lookup_name[63:16]};
                    else case(half_index)
                        4:image_cluster[15:0]<=read_word;
                        5:image_cluster[27:16]<=read_word[11:0];
                        6:image_size[15:0]<=read_word;
                        7:image_size[31:16]<=read_word;
                    endcase
                    if(half_index==7)begin
                        if(audio_count==0)begin state<=IDLE;result_valid<=1;end
                        else begin audio_index<=0;record_address<=MAX_IMAGES;half_index<=0;match_name<=1;state<=AUDIO_FETCH;end
                    end else begin half_index<=half_index+1'b1;state<=IMAGE_FETCH;end
                end
                AUDIO_FETCH:state<=AUDIO_USE;
                AUDIO_USE:begin
                    match_name<=match_name && read_word==lookup_name[15:0];
                    // 四次右旋后恢复图像名，下一音频记录仍从同一低半字开始比较。
                    lookup_name<={lookup_name[15:0],lookup_name[63:16]};
                    if(half_index==3)state<=AUDIO_SELECT;
                    else begin half_index<=half_index+1'b1;state<=AUDIO_FETCH;end
                end
                AUDIO_SELECT:begin
                    if(match_name)begin audio_found<=1;half_index<=4;state<=AUDIO_META_FETCH;end
                    else if(audio_index+1'b1>=audio_count)begin state<=IDLE;result_valid<=1;end
                    else begin
                        audio_index<=audio_index+1'b1;record_address<=MAX_IMAGES+audio_index+1'b1;
                        half_index<=0;match_name<=1;state<=AUDIO_FETCH;
                    end
                end
                AUDIO_META_FETCH:state<=AUDIO_META_USE;
                AUDIO_META_USE:begin
                    case(half_index)
                        4:audio_cluster[15:0]<=read_word;
                        5:audio_cluster[27:16]<=read_word[11:0];
                        6:audio_size[15:0]<=read_word;
                        7:audio_size[31:16]<=read_word;
                    endcase
                    if(half_index==7)begin state<=IDLE;result_valid<=1;end
                    else begin half_index<=half_index+1'b1;state<=AUDIO_META_FETCH;end
                end
            endcase
        end
    end
endmodule
