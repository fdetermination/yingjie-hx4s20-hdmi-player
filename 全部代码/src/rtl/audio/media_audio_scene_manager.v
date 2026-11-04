`timescale 1ns/1ps
// 存储域两WAV/槽生命周期与像素域双PCM场景边界；槽只在旧源排空/共同clear后复用。
module media_audio_scene_manager #(
    parameter integer TOKEN_BITS=8,PIXEL_HZ=74250000,SAMPLE_HZ=48000,FIFO_BITS=9,
    parameter integer PRELOAD_SAMPLES=128,READ_RESERVE=130
)(
    input wire clk,pixel_clk,rst,cancel_all,
    input wire [1:0] cancel_slot,
    output wire [1:0] cancel_ack,available,prepared,
    input wire prepare_valid,prepare_slot,prepare_has_audio,
    input wire [TOKEN_BITS-1:0] prepare_token,
    input wire [27:0] prepare_cluster,
    input wire [31:0] prepare_size,
    output wire prepare_ready,
    input wire arm_valid,arm_slot,cancel_scene,
    input wire [TOKEN_BITS-1:0] arm_token,
    output wire arm_ready,armed,scene_cancel_ack,
    output wire started,started_slot,scene_error,
    output wire [TOKEN_BITS-1:0] started_token,
    output reg current_valid,current_slot,
    input wire video_sof,video_scene_valid,
    input wire [TOKEN_BITS-1:0] video_scene_token,
    output wire [1:0] file_cmd_valid,file_cmd_channel,file_abort,file_data_ready,
    output wire [5:0] file_cmd_op,
    output wire [55:0] file_cmd_cluster,
    output wire [63:0] file_cmd_size,
    input wire [1:0] file_cmd_ready,file_done,file_error,file_open_complete,file_cancel_ack,file_data_valid,
    input wire [7:0] file_data_byte,
    input wire file_last,
    output wire [1:0] urgent,
    output wire sample_valid,audio_active,audio_done,audio_error,audio_underflow,
    output wire [7:0] error_detail,
    output wire signed [15:0] sample_left,sample_right,
    output wire [31:0] sample_count
);
    localparam IDLE=0,BIND=1,START=2,RUN=3,STOP=4,CLEAR=5,CLEAN=6,RELEASE=7;
    reg [2:0] state[0:1];
    reg [1:0] queue_clear,audio_found,format_error,fallback,retire;
    reg [TOKEN_BITS-1:0] token[0:1];
    reg [27:0] cluster[0:1];reg [31:0] size[0:1];
    wire [1:0] busy,source_ready,source_done,source_error,source_ack,source_abort,source_start,source_idle;
    wire [7:0] source_error_code;
    reg [3:0] first_source_error[0:1];
    reg [1:0] boundary_stable[0:1];
    wire [1:0] pcm_valid,pcm_ready,clear_ack,slot_ready,queue_prepare_ready,queue_prepared,read_room,low_water;
    wire [1:0] queue_prepare_valid,slot_underflow,track_done;
    wire [31:0] pcm_left,pcm_right;
    wire [2*(FIFO_BITS+1)-1:0] wr_used;
    wire scene_start,scene_slot,scene_has_audio,scene_accept,pixel_active,pixel_slot,pixel_scene_error;
    wire [TOKEN_BITS-1:0] scene_token,pixel_token;
    (* async_reg="true" *) reg active_meta,active_sync;
    assign urgent={current_valid && current_slot && low_water[1],current_valid && !current_slot && low_water[0]};
    assign prepare_ready=available[prepare_slot] && !cancel_all && !cancel_slot[prepare_slot];
    assign audio_active=active_sync;
    assign audio_done=|track_done;
    assign audio_error=current_valid && format_error[current_slot];
    assign error_detail={first_source_error[current_slot],current_slot,state[current_slot]};
    genvar slot;
    generate for(slot=0;slot<2;slot=slot+1)begin:sources
        assign available[slot]=state[slot]==IDLE && slot_ready[slot] && queue_prepare_ready[slot] && !cancel_all && !cancel_slot[slot];
        assign prepared[slot]=state[slot]==RUN && queue_prepared[slot] &&
            (!audio_found[slot] || (source_idle[slot] && boundary_stable[slot]==2));
        assign cancel_ack[slot]=state[slot]==CLEAN;
        assign queue_prepare_valid[slot]=state[slot]==BIND && !cancel_all && !cancel_slot[slot];
        assign source_start[slot]=state[slot]==START && pcm_ready[slot] && source_ready[slot] && !cancel_all && !cancel_slot[slot];
        assign source_abort[slot]=state[slot]==STOP || state[slot]==CLEAR || state[slot]==CLEAN;
        wav_file_player #(.TOKEN_BITS(TOKEN_BITS)) player(
            .clk(clk),.rst(rst),.start(source_start[slot]),.start_ready(source_ready[slot]),
            .file_cluster(cluster[slot]),.file_size(size[slot]),.file_slot(slot==1),.abort(source_abort[slot]),
            .busy(busy[slot]),.file_idle(source_idle[slot]),.done(source_done[slot]),.error(source_error[slot]),.cancel_ack(source_ack[slot]),.error_code(source_error_code[slot*4+:4]),
            .pcm_valid(pcm_valid[slot]),.pcm_ready(pcm_ready[slot]),
            .file_read_allow(read_room[slot] && ((current_valid && current_slot==slot) || !queue_prepared[slot])),
            .pcm_left(pcm_left[slot*16+:16]),.pcm_right(pcm_right[slot*16+:16]),
            .file_cmd_valid(file_cmd_valid[slot]),.file_cmd_ready(file_cmd_ready[slot]),.file_cmd_op(file_cmd_op[slot*3+:3]),
            .file_cmd_channel(file_cmd_channel[slot]),.file_cmd_cluster(file_cmd_cluster[slot*28+:28]),.file_cmd_size(file_cmd_size[slot*32+:32]),
            .file_done(file_done[slot]),.file_error(file_error[slot]),.file_open_complete(file_open_complete[slot]),
            .file_data_ready(file_data_ready[slot]),.file_data_valid(file_data_valid[slot]),.file_data_byte(file_data_byte),.file_last(file_last),
            .file_abort(file_abort[slot]),.file_cancel_ack(file_cancel_ack[slot]));
    end endgenerate
    pcm_dual_scene_stream #(.CLK_HZ(PIXEL_HZ),.SAMPLE_HZ(SAMPLE_HZ),.FIFO_BITS(FIFO_BITS),.TOKEN_BITS(TOKEN_BITS),
        .PRELOAD_SAMPLES(PRELOAD_SAMPLES),.READ_RESERVE(READ_RESERVE)) queues(
        .wr_clk(clk),.clk(pixel_clk),.rst(rst),.clear(queue_clear),.prepare_valid(queue_prepare_valid),.prepare_has_audio(audio_found),
        .prepare_token({token[1],token[0]}),.pcm_valid(pcm_valid),.source_done(source_done),.pcm_left(pcm_left),.pcm_right(pcm_right),
        .clear_ack(clear_ack),.slot_ready(slot_ready),.prepare_ready(queue_prepare_ready),.prepared(queue_prepared),
        .pcm_ready(pcm_ready),.read_room(read_room),.low_water(low_water),.wr_used(wr_used),
        .scene_start(scene_start),.scene_slot(scene_slot),.scene_has_audio(scene_has_audio),.scene_token(scene_token),.scene_accept(scene_accept),
        .scene_error(pixel_scene_error),.active(pixel_active),.active_slot(pixel_slot),.active_token(pixel_token),
        .sample_valid(sample_valid),.sample_left(sample_left),.sample_right(sample_right),.sample_count(sample_count),
        .underflow(audio_underflow),.slot_underflow(slot_underflow),.track_done(track_done));
    scene_audio_cdc #(.TOKEN_BITS(TOKEN_BITS)) scenes(
        .src_clk(clk),.dst_clk(pixel_clk),.rst(rst),.arm_valid(arm_valid),.arm_slot(arm_slot),.arm_has_audio(audio_found[arm_slot]),
        .arm_token(arm_token),.cancel(cancel_scene || cancel_all),.arm_ready(arm_ready),.armed(armed),.cancel_ack(scene_cancel_ack),
        .started(started),.error(scene_error),.started_slot(started_slot),.started_token(started_token),
        .video_sof(video_sof),.video_scene_valid(video_scene_valid),.video_scene_token(video_scene_token),
        .scene_start(scene_start),.scene_slot(scene_slot),.scene_has_audio(scene_has_audio),.scene_token(scene_token),.scene_accept(scene_accept));
    integer index;
    always @(posedge clk or posedge rst)begin
        if(rst)begin
            state[0]<=CLEAR;state[1]<=CLEAR;queue_clear<=3;audio_found<=0;format_error<=0;fallback<=0;retire<=0;
            token[0]<=0;token[1]<=0;cluster[0]<=0;cluster[1]<=0;size[0]<=0;size[1]<=0;
            current_valid<=0;current_slot<=0;active_meta<=0;active_sync<=0;
            boundary_stable[0]<=0;boundary_stable[1]<=0;
            first_source_error[0]<=0;first_source_error[1]<=0;
        end else begin
            active_meta<=pixel_active;active_sync<=active_meta;
            if(cancel_all)current_valid<=0;
            if(started && !cancel_all)begin
                if(current_valid && current_slot!=started_slot)retire[current_slot]<=1;
                current_valid<=1;current_slot<=started_slot;
            end
            for(index=0;index<2;index=index+1)begin
                if(state[index]!=RUN || !queue_prepared[index] || !source_idle[index] || pcm_valid[index])boundary_stable[index]<=0;
                else if(boundary_stable[index]<2)boundary_stable[index]<=boundary_stable[index]+1'b1;
                if(cancel_all || cancel_slot[index] || retire[index])fallback[index]<=0;
                if((cancel_all || cancel_slot[index] || retire[index]) && state[index]!=STOP && state[index]!=CLEAR && state[index]!=CLEAN)begin
                    state[index]<=STOP;queue_clear[index]<=1;fallback[index]<=0;
                end else case(state[index])
                    IDLE:if(prepare_valid && prepare_ready && prepare_slot==index)begin
                        token[index]<=prepare_token;cluster[index]<=prepare_cluster;size[index]<=prepare_size;
                        audio_found[index]<=prepare_has_audio;format_error[index]<=0;fallback[index]<=0;state[index]<=BIND;
                        first_source_error[index]<=0;
                    end
                    BIND:if(queue_prepare_valid[index] && queue_prepare_ready[index])state[index]<=audio_found[index]?START:RUN;
                    START:if(source_start[index])state[index]<=RUN;
                    RUN:if(audio_found[index] && source_error[index])begin
                        format_error[index]<=1;fallback[index]<=1;state[index]<=STOP;queue_clear[index]<=1;
                        if(!format_error[index])first_source_error[index]<=source_error_code[index*4+:4];
                    end
                    STOP:if(!busy[index] || source_ack[index])state[index]<=CLEAR;
                    CLEAR:if(clear_ack[index])state[index]<=CLEAN;
                    CLEAN:if(!cancel_all && !cancel_slot[index])begin queue_clear[index]<=0;retire[index]<=0;state[index]<=RELEASE;end
                    RELEASE:if(slot_ready[index])begin
                        if(fallback[index])begin audio_found[index]<=0;state[index]<=BIND;fallback[index]<=0;end
                        else state[index]<=IDLE;
                    end
                endcase
            end
        end
    end
endmodule
