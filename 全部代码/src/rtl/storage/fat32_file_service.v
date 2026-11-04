`timescale 1ns/1ps
// 自主 FAT32 只读服务：MBR/BPB、根目录、完整链验证、图片/音频双游标。
// 仅通过块接口访问介质，不依赖主机预扫描、不按物理字节搜索 BMP 标识。
module fat32_file_service #(
    parameter integer BLOCK_TIMEOUT_CYCLES=10_000_000,
    parameter integer MAX_CHAIN_HOPS=1_048_576,
    parameter integer MAX_DIRECTORY_ENTRIES=4096
)(
    input wire clk,rst,abort,
    input wire cmd_valid,
    output wire cmd_ready,
    input wire [2:0] cmd_op,
    input wire cmd_channel,
    input wire [27:0] cmd_cluster,
    input wire [31:0] cmd_size,
    output wire busy,
    output reg mounted,done,error,cancel_ack,open_complete,
    output reg [3:0] error_code,
    output wire entry_valid,
    input wire entry_ready,
    output reg [87:0] entry_name,
    output reg [1:0] entry_kind,
    output reg [27:0] entry_cluster,
    output reg [31:0] entry_size,
    output wire data_valid,
    input wire data_ready,
    output wire [7:0] data_byte,
    output wire file_last,
    output wire block_req,
    input wire block_accept,
    output wire [31:0] block_lba,
    input wire block_valid,
    output wire block_ready,
    input wire [7:0] block_data,
    input wire block_last,block_error,
    output wire block_cancel,
    input wire block_cancel_ack
);
    localparam IDLE=0,CACHE_START=1,CACHE_WAIT=2,WORD_WAIT=3,WORD_TAKE=4,
        BOOT=5,SIGNATURE=6,BPB_READ=7,BPB_STORE=8,BPB_CHECK=9,
        MBR_READ=10,MBR_STORE=11,MBR_CHECK=12,VOL_CALC=13,VOL_RANGE=14,VOL_CLUSTERS=15,
        DIR_SECTOR=16,DIR_ENTRY=17,DIR_WORD=18,DIR_CHECK=19,DIR_SEND=20,DIR_NEXT=21,
        FAT_SECTOR=22,FAT_WORD=23,FAT_CHECK=24,FILE_SECTOR=25,FILE_WORD=26,
        FILE_SEND=27,ABORT_START=28,ABORT_WAIT=29,FAT_CLASSIFY=30,VOL_BOUNDS=31,MBR_RANGE=32,
        OPEN_SIZE=33,OPEN_SHIFT=34,OPEN_COUNT=35;
    localparam FAT_DIR=0,FAT_OPEN=1,FAT_READ=2;
    localparam integer STATE_COUNT=36;
    // 返回值也保留一热编码，读块/读字完成时直接恢复状态位。
    reg [STATE_COUNT-1:0] state,after_cache,after_word;
    reg [2:0] operation;
    reg [1:0] fat_reason;
    reg channel;
    reg cache_start,cache_abort;
    reg [31:0] cache_lba;
    wire cache_busy,cache_done,cache_error;
    wire [3:0] cache_error_code;
    reg word_en;
    reg [6:0] word_addr;
    wire [31:0] word_data;
    reg [31:0] value;
    sd_sector_buffer #(.TIMEOUT_CYCLES(BLOCK_TIMEOUT_CYCLES)) sector (
        .clk(clk),.rst(rst),.start(cache_start),.abort(cache_abort),.lba(cache_lba),
        .busy(cache_busy),.done(cache_done),.error(cache_error),.error_code(cache_error_code),
        .block_req(block_req),.block_accept(block_accept),.block_lba(block_lba),
        .block_valid(block_valid),.block_ready(block_ready),.block_data(block_data),
        .block_last(block_last),.block_error(block_error),.block_cancel(block_cancel),
        .block_cancel_ack(block_cancel_ack),.word_en(word_en),.word_addr(word_addr),.word_data(word_data)
    );

    reg partitioned;
    reg [31:0] volume_base,partition_size,total_sectors,fat_size;
    reg [31:0] fat_base,data_base;
    reg [27:0] cluster_count,cluster_limit,root_cluster;
    reg [7:0] sectors_per_cluster,fat_count;
    reg [3:0] cluster_shift,active_fat;
    reg [15:0] reserved_sectors,bps,root_entries,total16,fat16,flags,version;
    reg [7:0] jump_byte;
    reg bpb_boot_valid,bpb_layout_valid;
    reg [31:0] root_raw;
    reg [63:0] overhead,data_fat_capacity;
    // 阈值仅28位；容量高位非零时必然足够，保留完整64位语义并缩短比较链。
    wire fat_capacity_shortage=data_fat_capacity[63:28]==0 && data_fat_capacity[27:0]<cluster_count;
    reg [31:0] cluster_count_full;
    reg [3:0] field_index;
    reg [1:0] partition_index;
    reg [7:0] partition_type;
    reg [15:0] mbr_start_low,mbr_size_low;
    reg [31:0] mbr_start,mbr_size;
    reg [32:0] range_end;
    reg [2:0] part_word;

    reg [27:0] current_cluster,anchor,power,chain_length,chain_steps;
    reg [7:0] sector_index;
    reg [31:0] entry_count;
    reg [3:0] slot;
    reg [2:0] dir_word_index;
    reg [31:0] dir_words[0:7];
    wire [31:0] directory_cluster={dir_words[5][15:0],dir_words[6][31:16]};
    wire [7:0] attr=dir_words[2][31:24];
    wire bmp_extension=((dir_words[2][7:0]|8'h20)==8'h62) &&
                       ((dir_words[2][15:8]|8'h20)==8'h6d) && ((dir_words[2][23:16]|8'h20)==8'h70);
    wire wav_extension=((dir_words[2][7:0]|8'h20)==8'h77) &&
                       ((dir_words[2][15:8]|8'h20)==8'h61) && ((dir_words[2][23:16]|8'h20)==8'h76);
    wire [27:0] next_cluster=value[27:0];
    reg fat_eoc,fat_valid,fat_loop,fat_short,fat_advance_anchor;
    reg [27:0] opened_cluster,needed_clusters;
    reg [31:0] opened_size;
    reg [31:0] open_size_minus_one;
    reg [22:0] open_clusters_minus_one;
    reg [1:0] context_valid;
    reg [27:0] context_cluster[0:1];
    reg [7:0] context_sector[0:1];
    reg [31:0] context_remaining[0:1];
    reg [1:0] open_pending;
    reg [27:0] open_first[0:1],open_needed[0:1],open_current[0:1],open_anchor[0:1];
    reg [27:0] open_power[0:1],open_length[0:1],open_steps[0:1];
    reg [31:0] open_size[0:1];
    reg [9:0] byte_count,chunk_length;
    reg [1:0] byte_lane;
    // 有效数据请求中sector_index<2^cluster_shift，低位互斥，可用OR合并偏移而无需第二次加法。
    wire [31:0] data_cluster_offset=(current_cluster-32'd2)<<cluster_shift[2:0];
    wire [31:0] data_sector_lba=data_base+(data_cluster_offset|{24'd0,sector_index});

    assign busy=!state[IDLE];
    assign cmd_ready=state[IDLE] && !abort;
    assign entry_valid=state[DIR_SEND] && !abort;
    assign data_valid=state[FILE_SEND] && !abort;
    assign data_byte=value>>(byte_lane*8);
    assign file_last=data_valid && context_remaining[channel]==1;
    wire file_operation=operation==2 || operation==3 || operation==4 || operation==5;
    wire stepped_open=operation==4 || operation==5;

    function [STATE_COUNT-1:0] state_mask;
        input [5:0] index;
        begin state_mask=36'd1<<index;end
    endfunction
    function [3:0] log2_spc;
        input [7:0] spc;
        begin
            case(spc)
                1:log2_spc=0;2:log2_spc=1;4:log2_spc=2;8:log2_spc=3;
                16:log2_spc=4;32:log2_spc=5;64:log2_spc=6;128:log2_spc=7;
                default:log2_spc=15;
            endcase
        end
    endfunction
    function valid_cluster;
        input [27:0] c;
        begin valid_cluster=c>=2 && c<28'hffffff0 && c<=cluster_limit; end
    endfunction
    task fetch;
        input [31:0] address;
        input [5:0] return_state;
        begin cache_lba<=address;cache_start<=1;after_cache<=state_mask(return_state);state<=state_mask(CACHE_START);end
    endtask
    task read_word;
        input [6:0] address;
        input [5:0] return_state;
        begin word_addr<=address;word_en<=1;after_word<=state_mask(return_state);state<=state_mask(WORD_WAIT);end
    endtask
    task complete;
        begin state<=state_mask(IDLE);done<=1;end
    endtask
    task fail_status;
        input [3:0] code;
        begin
            error<=1;error_code<=code;done<=0;open_complete<=0;state<=state_mask(IDLE);
            if(operation==0) mounted<=0;
        end
    endtask
    task fail;
        input [3:0] code;
        begin
            fail_status(code);
            if(file_operation)begin context_valid[channel]<=0;open_pending[channel]<=0;end
        end
    endtask
    task begin_chain;
        input [27:0] first_cluster;
        begin current_cluster<=first_cluster;anchor<=first_cluster;power<=1;chain_length<=0;chain_steps<=1;end
    endtask

    always @(posedge clk or posedge rst) begin
        if(rst) begin
            state<=state_mask(IDLE);mounted<=0;done<=0;error<=0;error_code<=0;cancel_ack<=0;open_complete<=0;
            cache_start<=0;cache_abort<=0;word_en<=0;context_valid<=0;open_pending<=0;
            operation<=0;channel<=0;volume_base<=0;partitioned<=0;partition_size<=0;
            cache_lba<=0;word_addr<=0;value<=0;after_cache<=state_mask(IDLE);after_word<=state_mask(IDLE);
            entry_name<=0;entry_kind<=0;entry_cluster<=0;entry_size<=0;
            total_sectors<=0;fat_size<=0;fat_base<=0;data_base<=0;cluster_count<=0;cluster_limit<=0;root_cluster<=0;
            sectors_per_cluster<=0;fat_count<=0;cluster_shift<=0;active_fat<=0;reserved_sectors<=0;
            bps<=0;root_entries<=0;total16<=0;fat16<=0;flags<=0;version<=0;jump_byte<=0;root_raw<=0;
            bpb_boot_valid<=0;bpb_layout_valid<=0;
            overhead<=0;data_fat_capacity<=0;cluster_count_full<=0;field_index<=0;partition_index<=0;partition_type<=0;
            mbr_start_low<=0;mbr_size_low<=0;mbr_start<=0;mbr_size<=0;range_end<=0;part_word<=0;
            current_cluster<=0;anchor<=0;power<=0;chain_length<=0;chain_steps<=0;sector_index<=0;
            entry_count<=0;slot<=0;dir_word_index<=0;fat_reason<=0;
            fat_eoc<=0;fat_valid<=0;fat_loop<=0;fat_short<=0;fat_advance_anchor<=0;
            opened_cluster<=0;opened_size<=0;needed_clusters<=0;open_size_minus_one<=0;open_clusters_minus_one<=0;
            byte_count<=0;chunk_length<=0;byte_lane<=0;
            context_cluster[0]<=0;context_cluster[1]<=0;context_sector[0]<=0;context_sector[1]<=0;
            context_remaining[0]<=0;context_remaining[1]<=0;
        end else begin
            cache_start<=0;cache_abort<=0;word_en<=0;cancel_ack<=0;
            if(abort && !state[ABORT_START] && !state[ABORT_WAIT]) begin
                cache_abort<=1;state<=state_mask(ABORT_START);done<=0;error<=0;error_code<=0;open_complete<=0;
                // 空闲取消没有在途owner，不能按上一条命令失效已经完成或暂停的槽。
                if(!state[IDLE])begin
                    if(operation==0) mounted<=0;
                    if(file_operation)begin context_valid[channel]<=0;open_pending[channel]<=0;end
                end
            end else (* parallel_case *) case(1'b1)
                state[ABORT_START]: state<=state_mask(ABORT_WAIT);
                state[ABORT_WAIT]: if(!cache_busy) begin
                    cancel_ack<=1;
                    // 上游允许保持 abort 直到确认；确认不能反过来等待 abort 先撤销。
                    if(!abort) state<=state_mask(IDLE);
                end
                state[IDLE]: if(cmd_valid && cmd_ready) begin
                    done<=0;error<=0;error_code<=0;open_complete<=0;operation<=cmd_op;channel<=cmd_channel;
                    case(cmd_op)
                        0: begin mounted<=0;context_valid<=0;open_pending<=0;partitioned<=0;volume_base<=0;fetch(0,BOOT);end
                        1: if(!mounted) begin error<=1;error_code<=1;end
                           else begin begin_chain(root_cluster);sector_index<=0;entry_count<=0;state<=state_mask(DIR_SECTOR);end
                        2,4: begin
                           context_valid[cmd_channel]<=0;open_pending[cmd_channel]<=0;
                           if(!mounted) begin error<=1;error_code<=1;end
                           else begin
                               opened_cluster<=cmd_cluster;opened_size<=cmd_size;
                               open_first[cmd_channel]<=cmd_cluster;open_size[cmd_channel]<=cmd_size;
                               if(cmd_size==0) begin
                                   context_valid[cmd_channel]<=1;context_remaining[cmd_channel]<=0;
                                   context_cluster[cmd_channel]<=0;context_sector[cmd_channel]<=0;done<=1;open_complete<=1;
                               end
                               else if(!valid_cluster(cmd_cluster)) begin error<=1;error_code<=6;end
                               else state<=state_mask(OPEN_SIZE);
                           end
                           end
                        3: if(!mounted || !context_valid[cmd_channel]) begin error<=1;error_code<=10;end
                           else if(context_remaining[cmd_channel]==0) done<=1;
                           else begin
                               current_cluster<=context_cluster[cmd_channel];sector_index<=context_sector[cmd_channel];
                               byte_count<=0;byte_lane<=0;
                               chunk_length<=(context_remaining[cmd_channel]>512)?512:context_remaining[cmd_channel][9:0];
                               state<=state_mask(FILE_SECTOR);
                           end
                        5: if(!mounted || !open_pending[cmd_channel])begin error<=1;error_code<=10;end
                           else begin
                               opened_cluster<=open_first[cmd_channel];opened_size<=open_size[cmd_channel];
                               needed_clusters<=open_needed[cmd_channel];current_cluster<=open_current[cmd_channel];
                               anchor<=open_anchor[cmd_channel];power<=open_power[cmd_channel];
                               chain_length<=open_length[cmd_channel];chain_steps<=open_steps[cmd_channel];
                               fat_reason<=FAT_OPEN;state<=state_mask(FAT_SECTOR);
                           end
                        default:begin error<=1;error_code<=11;end
                    endcase
                end
                state[CACHE_START]: state<=state_mask(CACHE_WAIT);
                // size>0时ceil(size/cluster_bytes)=((size-1)>>log2(cluster_bytes))+1，分拍避免宽加法串移位。
                state[OPEN_SIZE]:begin open_size_minus_one<=opened_size-1'b1;state<=state_mask(OPEN_SHIFT);end
                state[OPEN_SHIFT]:begin open_clusters_minus_one<=open_size_minus_one>>(cluster_shift+9);state<=state_mask(OPEN_COUNT);end
                state[OPEN_COUNT]:begin
                    needed_clusters<={5'd0,open_clusters_minus_one}+1'b1;
                    open_needed[channel]<={5'd0,open_clusters_minus_one}+1'b1;
                    begin_chain(opened_cluster);fat_reason<=FAT_OPEN;state<=state_mask(FAT_SECTOR);
                end
                state[CACHE_WAIT]: if(cache_error) fail(5); else if(cache_done) state<=after_cache;
                state[WORD_WAIT]: state<=state_mask(WORD_TAKE);
                state[WORD_TAKE]: begin value<=word_data;state<=after_word;end
                state[BOOT]: read_word(127,SIGNATURE);
                state[SIGNATURE]: if(value[31:16]!=16'haa55) fail_status(2);
                           else begin field_index<=0;state<=state_mask(BPB_READ);end
                state[BPB_READ]: begin
                    case(field_index)
                        0:read_word(0,BPB_STORE);1:read_word(2,BPB_STORE);2:read_word(3,BPB_STORE);
                        3:read_word(4,BPB_STORE);4:read_word(5,BPB_STORE);5:read_word(8,BPB_STORE);
                        6:read_word(9,BPB_STORE);7:read_word(10,BPB_STORE);8:read_word(11,BPB_STORE);
                    endcase
                end
                state[BPB_STORE]: begin
                    case(field_index)
                        0:jump_byte<=value[7:0];
                        1:bps[7:0]<=value[31:24];
                        2:begin bps[15:8]<=value[7:0];sectors_per_cluster<=value[15:8];reserved_sectors<=value[31:16];end
                        3:begin fat_count<=value[7:0];root_entries<=value[23:8];total16[7:0]<=value[31:24];end
                        4:begin total16[15:8]<=value[7:0];fat16<=value[31:16];end
                        5:total_sectors<=value;6:fat_size<=value;
                        7:begin flags<=value[15:0];version<=value[31:16];end
                        8:root_raw<=value;
                    endcase
                    // Root is the last field; every layout-check input is already stable.
                    if(field_index==8)begin
                        bpb_boot_valid<=bps==512 && (jump_byte==8'heb || jump_byte==8'he9);
                        bpb_layout_valid<=log2_spc(sectors_per_cluster)!=15 && reserved_sectors!=0 &&
                            (fat_count==1 || fat_count==2) && root_entries==0 && total16==0 &&
                            fat16==0 && fat_size!=0 && version==0 && (!flags[7] || flags[3:0]<fat_count);
                    end
                    field_index<=field_index+1'b1;state<=state_mask((field_index==8)?BPB_CHECK:BPB_READ);
                end
                state[BPB_CHECK]: begin
                    if(!partitioned && !bpb_boot_valid) begin
                        partition_index<=0;part_word<=0;state<=state_mask(MBR_READ);
                    end else if(!bpb_boot_valid || !bpb_layout_valid) fail_status(3);
                    else begin cluster_shift<=log2_spc(sectors_per_cluster);active_fat<=flags[7]?flags[3:0]:0;state<=state_mask(VOL_CALC);end
                end
                state[MBR_READ]: read_word(112+{partition_index,2'b00}+part_word,MBR_STORE);
                state[MBR_STORE]: begin
                    case(part_word)
                        0:partition_type<=value[23:16];
                        1:mbr_start_low<=value[31:16];
                        2:begin mbr_start<={value[15:0],mbr_start_low};mbr_size_low<=value[31:16];end
                        3:mbr_size<={value[15:0],mbr_size_low};
                    endcase
                    part_word<=part_word+1'b1;state<=state_mask((part_word==3)?MBR_RANGE:MBR_READ);
                end
                state[MBR_RANGE]: begin
                    // 完整分区字段就绪后先保存33bit半开区间终点，再决定挂载/拒绝。
                    range_end<={1'b0,mbr_start}+{1'b0,mbr_size};state<=state_mask(MBR_CHECK);
                end
                state[MBR_CHECK]: begin
                    if((partition_type==8'h0b || partition_type==8'h0c) && mbr_start!=0 && mbr_size!=0) begin
                        if(range_end>33'h100000000) fail_status(4);
                        else begin volume_base<=mbr_start;partition_size<=mbr_size;partitioned<=1;fetch(mbr_start,BOOT);end
                    end else if(partition_index==3) fail_status(2);
                    else begin partition_index<=partition_index+1'b1;part_word<=0;state<=state_mask(MBR_READ);end
                end
                state[VOL_CALC]: begin
                    // BPB已限定1或2张FAT，位1直接表示双表，避免宽译码串入加法。
                    overhead<={48'd0,reserved_sectors}+(fat_count[1]?({32'd0,fat_size}<<1):{32'd0,fat_size});
                    // MBR检查已结束，复用终点寄存器断开卷范围加法到错误状态的组合路径。
                    range_end<={1'b0,volume_base}+{1'b0,total_sectors};
                    // BPB已排除零FAT；先扣除保留项0/1，避免校验时把簇数加法串入状态。
                    data_fat_capacity<={25'd0,(fat_size-32'd1),7'd126};state<=state_mask(VOL_RANGE);
                end
                state[VOL_RANGE]: begin
                    if(overhead>=total_sectors || (partitioned && total_sectors>partition_size) ||
                       range_end>33'h100000000) fail_status(4);
                    else begin
                        cluster_count<=(total_sectors-overhead)>>cluster_shift;
                        cluster_count_full<=(total_sectors-overhead)>>cluster_shift;
                        data_base<=volume_base+overhead;
                        fat_base<=volume_base+reserved_sectors+((active_fat==0)?0:fat_size);
                        state<=state_mask(VOL_BOUNDS);
                    end
                end
                state[VOL_BOUNDS]: begin
                    // 卷几何在挂载后固定，避免每次校验簇时把上限加法串到控制路径。
                    cluster_limit<=cluster_count+1'b1;
                    state<=state_mask(VOL_CLUSTERS);
                end
                state[VOL_CLUSTERS]: begin
                    if(cluster_count_full<65525 || cluster_count_full>=32'h0ffffff0 ||
                       fat_capacity_shortage || root_raw[31:28]!=0 || !valid_cluster(root_raw[27:0])) fail_status(4);
                    else begin root_cluster<=root_raw[27:0];mounted<=1;complete();end
                end
                state[DIR_SECTOR]: begin
                    slot<=0;fetch(data_sector_lba,DIR_ENTRY);
                end
                state[DIR_ENTRY]: begin dir_word_index<=0;read_word({slot,3'b000},DIR_WORD);end
                state[DIR_WORD]: begin
                    dir_words[dir_word_index]<=value;
                    if(dir_word_index==7) state<=state_mask(DIR_CHECK);
                    else begin dir_word_index<=dir_word_index+1'b1;read_word({slot,3'b000}+dir_word_index+1'b1,DIR_WORD);end
                end
                state[DIR_CHECK]: begin
                    entry_count<=entry_count+1'b1;
                    if(entry_count>=MAX_DIRECTORY_ENTRIES) fail_status(9);
                    else if(dir_words[0][7:0]==0) complete();
                    else if(dir_words[0][7:0]==8'he5 || attr[4] || attr[3] || !(bmp_extension || wav_extension)) state<=state_mask(DIR_NEXT);
                    else if(dir_words[7]!=0 && (directory_cluster[31:28]!=0 || !valid_cluster(directory_cluster[27:0]))) fail_status(6);
                    else begin
                        entry_name<={dir_words[0][7:0],dir_words[0][15:8],dir_words[0][23:16],dir_words[0][31:24],
                                     dir_words[1][7:0],dir_words[1][15:8],dir_words[1][23:16],dir_words[1][31:24],
                                     dir_words[2][7:0],dir_words[2][15:8],dir_words[2][23:16]};
                        entry_cluster<=directory_cluster[27:0];entry_size<=dir_words[7];entry_kind<=bmp_extension?1:2;
                        state<=state_mask(DIR_SEND);
                    end
                end
                state[DIR_SEND]: if(entry_ready) state<=state_mask(DIR_NEXT);
                state[DIR_NEXT]: if(slot!=15) begin slot<=slot+1'b1;state<=state_mask(DIR_ENTRY);end
                          else if(sector_index+1<sectors_per_cluster) begin sector_index<=sector_index+1'b1;state<=state_mask(DIR_SECTOR);end
                          else begin fat_reason<=FAT_DIR;state<=state_mask(FAT_SECTOR);end
                state[FAT_SECTOR]: fetch(fat_base+(current_cluster>>7),FAT_WORD);
                state[FAT_WORD]: read_word(current_cluster[6:0],FAT_CLASSIFY);
                state[FAT_CLASSIFY]: begin
                    // value保持至下一拍提交；先分类，切断扇区RAM到游标/链计数使能的组合路径。
                    fat_eoc<=next_cluster>=28'hffffff8;
                    fat_valid<=valid_cluster(next_cluster);
                    fat_loop<=next_cluster==current_cluster || next_cluster==anchor ||
                              chain_steps>=cluster_count || chain_steps>=MAX_CHAIN_HOPS;
                    fat_short<=chain_steps<needed_clusters;
                    fat_advance_anchor<=chain_length+1>=power;
                    state<=state_mask(FAT_CHECK);
                end
                state[FAT_CHECK]: begin
                    // EOC优先于预算，READ不使用OPEN/LIST留下的Brent状态。
                    if(fat_eoc) begin
                        if(fat_reason==FAT_DIR) complete();
                        else if(fat_reason==FAT_READ || fat_short) fail(7);
                        else begin
                            context_valid[channel]<=1;context_cluster[channel]<=opened_cluster;
                            context_sector[channel]<=0;context_remaining[channel]<=opened_size;
                            open_pending[channel]<=0;open_complete<=1;complete();
                        end
                    end else if(!fat_valid) fail(6);
                    else if(fat_reason!=FAT_READ && fat_loop) fail(8);
                    else begin
                        current_cluster<=next_cluster;sector_index<=0;
                        if(fat_reason!=FAT_READ) begin
                            chain_steps<=chain_steps+1'b1;
                            if(fat_advance_anchor) begin anchor<=next_cluster;power<=power<<1;chain_length<=0;end
                            else chain_length<=chain_length+1'b1;
                        end
                        case(fat_reason)
                            FAT_DIR: state<=state_mask(DIR_SECTOR);
                            FAT_OPEN: if(stepped_open)begin
                                // 保存推进后的Brent状态；共享工作寄存器可立即给另槽READ/LIST使用。
                                open_current[channel]<=next_cluster;open_steps[channel]<=chain_steps+1'b1;
                                open_anchor[channel]<=fat_advance_anchor?next_cluster:anchor;
                                open_power[channel]<=fat_advance_anchor?(power<<1):power;
                                open_length[channel]<=fat_advance_anchor?28'd0:chain_length+1'b1;
                                open_pending[channel]<=1;complete();
                            end else state<=state_mask(FAT_SECTOR);
                            FAT_READ: begin context_cluster[channel]<=next_cluster;context_sector[channel]<=0;state<=state_mask(FILE_SECTOR);end
                        endcase
                    end
                end
                state[FILE_SECTOR]: if(sector_index==sectors_per_cluster) begin fat_reason<=FAT_READ;state<=state_mask(FAT_SECTOR);end
                             else fetch(data_sector_lba,FILE_WORD);
                state[FILE_WORD]: read_word(byte_count[8:2],FILE_SEND);
                state[FILE_SEND]: if(data_ready) begin
                    context_remaining[channel]<=context_remaining[channel]-1'b1;
                    if(byte_count+1==chunk_length) begin context_sector[channel]<=sector_index+1'b1;complete();end
                    else begin
                        byte_count<=byte_count+1'b1;byte_lane<=byte_lane+1'b1;
                        if(byte_lane==3) state<=state_mask(FILE_WORD);
                    end
                end
            endcase
        end
    end
endmodule
