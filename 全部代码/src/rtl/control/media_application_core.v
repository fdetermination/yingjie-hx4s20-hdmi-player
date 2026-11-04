`timescale 1ns/1ps
// 映界应用编排层：目录描述符 -> 播放控制 -> 图片加载 -> 帧提交。
// 存储、视频扫描和HDMI分别通过公共握手接口连接，避免控制器依赖任何参考顶层。
module media_application_core #(
    parameter integer CLK_FREQ_HZ=100_000_000,
    parameter integer MAX_IMAGES=4,
    parameter integer OUTPUT_WIDTH=1280,OUTPUT_HEIGHT=720,
    parameter integer TOKEN_BITS=8,
    parameter integer REQUEST_TIMEOUT_CYCLES=CLK_FREQ_HZ,
    parameter integer LOAD_TIMEOUT_CYCLES=CLK_FREQ_HZ*10,
    parameter integer COMMIT_TIMEOUT_CYCLES=CLK_FREQ_HZ*2,
    parameter integer ENABLE_TRANSITION=0,
    parameter integer PIXEL_HZ=74250000,SAMPLE_HZ=48000,AUDIO_FIFO_BITS=9,
    parameter integer AUDIO_PRELOAD=128,AUDIO_READ_RESERVE=130,
    parameter integer BILINEAR_ENABLE=0
)(
    input wire clk,pixel_clk,rst,restart,
    input wire video_scene_sof,video_scene_valid,
    input wire [TOKEN_BITS-1:0] video_scene_token,
    input wire scan_start,scan_done,scan_error,
    input wire entry_valid,
    output wire entry_ready,
    input wire [87:0] entry_name,
    input wire [1:0] entry_kind,
    input wire [27:0] entry_cluster,
    input wire [31:0] entry_size,
    input wire key_next,key_auto,
    input wire [1:0] interval_sel,
    output wire [1:0] display_locks,
    input wire frame_boundary,display_idle,fifo0_empty,fifo1_empty,
    input wire transition_done,display_error,
    output wire scan_dual,scan_next_bank,session_reconfigure,
    output wire display_valid,display_bank,
    output wire [TOKEN_BITS-1:0] scan_scene_token,
    output wire [TOKEN_BITS-1:0] display_epoch,
    output wire commit_pending,
    output wire display_cancel,
    output wire [3:0] app_error,
    output wire [15:0] error_detail,
    output wire [15:0] playback_status,
    output wire audio_active,audio_done,audio_error,
    output wire sample_valid,audio_underflow,
    output wire signed [15:0] sample_left,sample_right,
    output wire [31:0] sample_count,
    output wire file_cmd_valid,
    input wire file_cmd_ready,
    output wire [2:0] file_cmd_op,
    output wire file_cmd_channel,
    output wire [27:0] file_cmd_cluster,
    output wire [31:0] file_cmd_size,
    input wire file_done,file_error,file_open_complete,
    input wire file_data_valid,
    output wire file_data_ready,
    input wire [7:0] file_data_byte,
    input wire file_last,
    output wire file_abort,
    input wire file_cancel_ack,
    output wire mem_begin_req,
    input wire mem_begin_accept,
    output wire mem_bank,
    output wire [TOKEN_BITS-1:0] mem_token,
    output wire mem_write_valid,
    input wire mem_write_ready,
    output wire [20:0] mem_write_address,
    output wire [31:0] mem_write_data,
    output wire mem_flush_req,
    input wire mem_flush_ack,mem_error,
    input wire [TOKEN_BITS-1:0] mem_response_token,
    output wire mem_cancel,
    input wire mem_cancel_ack
);
    localparam INDEX_BITS=(MAX_IMAGES<2)?1:$clog2(MAX_IMAGES);
    wire ctrl_load_req,ctrl_load_accept,ctrl_load_buffer,ctrl_load_cancel,ctrl_cancel_flush;
    wire [INDEX_BITS-1:0] ctrl_load_index;
    wire [TOKEN_BITS-1:0] ctrl_load_token;
    wire ctrl_frame_ready,ctrl_frame_error;
    wire [TOKEN_BITS-1:0] ctrl_frame_token;
    wire ctrl_commit_req,ctrl_commit_accept;
    wire [TOKEN_BITS-1:0] ctrl_commit_token;
    wire ctrl_display_commit,ctrl_auto,ctrl_busy;
    wire [INDEX_BITS-1:0] ctrl_display_index;
    wire ctrl_display_buffer;
    wire [2:0] ctrl_interval;
    wire [3:0] ctrl_error;
    wire catalog_query_valid,catalog_query_ready,catalog_result_valid,catalog_result_ready,catalog_found,catalog_audio_found;
    wire [27:0] catalog_image_cluster,catalog_audio_cluster;
    wire [31:0] catalog_image_size,catalog_audio_size;
    reg descriptor_valid,query_inflight,catalog_done_seen,scan_failed;
    reg scan_result_pending,scan_result_error;
    wire ctrl_scan_ready;
    wire catalog_done,catalog_error;
    wire [INDEX_BITS:0] image_count;
    reg [27:0] descriptor_cluster;
    reg [31:0] descriptor_size;
    wire loader_load_req,loader_load_accept,loader_cancel_ack,loader_frame_ready,loader_frame_error;
    wire [TOKEN_BITS-1:0] loader_frame_token;
    wire [3:0] loader_error;
    wire loader_busy;
    wire loader_file_cmd_valid,loader_file_cmd_ready,loader_file_data_valid,loader_file_data_ready;
    wire [2:0] loader_file_cmd_op;wire loader_file_cmd_channel;
    wire [27:0] loader_file_cmd_cluster;wire [31:0] loader_file_cmd_size;
    wire loader_file_done,loader_file_error,loader_file_cancel_ack,loader_file_abort,loader_file_open_complete;
    wire [7:0] loader_file_data_byte;wire loader_file_last;
    wire [1:0] audio_file_cmd_valid,audio_file_cmd_ready,audio_file_data_ready,audio_file_abort;
    wire [5:0] audio_file_cmd_op;wire [1:0] audio_file_cmd_channel;
    wire [55:0] audio_file_cmd_cluster;wire [63:0] audio_file_cmd_size;
    wire staged_cmd_valid,staged_cmd_ready,staged_channel,staged_abort,staged_data_ready;
    wire [2:0] staged_op;
    wire [27:0] staged_cluster;wire [31:0] staged_size;
    wire [2:0] arb_ready,arb_done,arb_error,arb_complete,arb_cancel_ack,arb_data_valid;
    wire [7:0] arb_byte;wire arb_last,file_flush_ack;
    reg file_flush_req;
    wire [1:0] audio_available,audio_prepared,audio_cancel_ack,audio_urgent;
    wire audio_prepare_ready,scene_arm_ready,scene_armed,scene_cancel_ack,scene_started,scene_started_slot,scene_error;
    wire [TOKEN_BITS-1:0] scene_started_token;
    wire current_audio_valid,current_audio_slot;
    wire [7:0] audio_error_detail;
    reg audio_descriptor_valid;
    reg [27:0] audio_descriptor_cluster;reg [31:0] audio_descriptor_size;
    reg image_ready,audio_requested,frame_published,arm_requested,matching_started;
    reg work_slot;
    reg [TOKEN_BITS-1:0] work_token;
    wire frame_cancel_ack;
    wire ctrl_display_valid;
    assign ctrl_frame_ready=image_ready && audio_requested && scene_armed && !frame_published && !ctrl_load_cancel && !restart;
    // 已排空的会话可能仍保持错误，下一首图必须能启动新session来清除旧终态。
    wire current_display_error=ENABLE_TRANSITION && ctrl_commit_req && display_valid && display_error &&
        (current_audio_valid || matching_started);
    assign ctrl_frame_error=loader_frame_error || current_display_error || scene_error;
    assign ctrl_frame_token=current_display_error?ctrl_load_token:loader_frame_token;
    wire cancel_everything=restart || ctrl_cancel_flush;
    wire [1:0] cancel_audio=cancel_everything?2'b11:(ctrl_load_cancel?(2'b01<<work_slot):2'b00);
    wire commit_cancel_ack=loader_cancel_ack && frame_cancel_ack && scene_cancel_ack && !file_flush_req && !query_inflight &&
        (cancel_everything?(&audio_cancel_ack):audio_cancel_ack[work_slot]);
    // 目录查询只发一次；取消后仍收走迟到结果，但不会交给下一事务。
    assign catalog_query_valid=ctrl_load_req && !descriptor_valid && !query_inflight && !ctrl_load_cancel && !restart;
    assign catalog_result_ready=query_inflight;
    assign app_error=scan_failed?4'd7:(audio_error?4'd8:ctrl_error);
    assign error_detail={ctrl_error,ctrl_busy,ctrl_load_cancel,ctrl_commit_req,ctrl_load_req,audio_error_detail};
    assign commit_pending=ctrl_commit_req;
    assign display_cancel=ctrl_cancel_flush;
    wire target_slot=current_audio_valid?~current_audio_slot:1'b0;
    assign loader_load_req=ctrl_load_req && descriptor_valid && !ctrl_load_cancel && !restart && audio_available[target_slot];
    assign ctrl_load_accept=loader_load_req && loader_load_accept;
    assign staged_cmd_ready=arb_ready[0];assign audio_file_cmd_ready=arb_ready[2:1];
    file_sector_stager image_sectors(
        .clk(clk),.rst(rst),.app_abort(loader_file_abort),.app_cmd_valid(loader_file_cmd_valid),.app_cmd_ready(loader_file_cmd_ready),
        .app_cmd_op(loader_file_cmd_op),.app_cmd_channel(loader_file_cmd_channel),.app_cmd_cluster(loader_file_cmd_cluster),.app_cmd_size(loader_file_cmd_size),
        .app_done(loader_file_done),.app_error(loader_file_error),.app_open_complete(loader_file_open_complete),.app_cancel_ack(loader_file_cancel_ack),
        .app_data_valid(loader_file_data_valid),.app_data_ready(loader_file_data_ready),.app_data_byte(loader_file_data_byte),.app_file_last(loader_file_last),
        .service_cmd_valid(staged_cmd_valid),.service_cmd_ready(staged_cmd_ready),.service_cmd_op(staged_op),.service_cmd_channel(staged_channel),
        .service_cmd_cluster(staged_cluster),.service_cmd_size(staged_size),.service_done(arb_done[0]),.service_error(arb_error[0]),
        .service_open_complete(arb_complete[0]),.service_cancel_ack(arb_cancel_ack[0]),.service_abort(staged_abort),.service_inflight(),
        .service_data_valid(arb_data_valid[0]),.service_data_ready(staged_data_ready),.service_data_byte(arb_byte),.service_file_last(arb_last));
    media_file_arbiter files(
        .clk(clk),.rst(rst),.flush_req(restart || file_flush_req),.flush_ack(file_flush_ack),
        .client_cmd_valid({audio_file_cmd_valid,staged_cmd_valid}),.client_abort({audio_file_abort,staged_abort}),.client_urgent({audio_urgent,1'b0}),
        .client_cmd_ready(arb_ready),.client_cmd_op({audio_file_cmd_op,staged_op}),.client_cmd_channel({audio_file_cmd_channel,staged_channel}),
        .client_cmd_cluster({audio_file_cmd_cluster,staged_cluster}),.client_cmd_size({audio_file_cmd_size,staged_size}),
        .client_done(arb_done),.client_error(arb_error),.client_open_complete(arb_complete),.client_cancel_ack(arb_cancel_ack),
        .client_data_valid(arb_data_valid),.client_data_ready({audio_file_data_ready,staged_data_ready}),.client_data_byte(arb_byte),.client_file_last(arb_last),
        .service_cmd_valid(file_cmd_valid),.service_cmd_ready(file_cmd_ready),.service_cmd_op(file_cmd_op),.service_cmd_channel(file_cmd_channel),
        .service_cmd_cluster(file_cmd_cluster),.service_cmd_size(file_cmd_size),.service_done(file_done),.service_error(file_error),
        .service_open_complete(file_open_complete),.service_cancel_ack(file_cancel_ack),.service_abort(file_abort),
        .service_data_valid(file_data_valid),.service_data_ready(file_data_ready),.service_data_byte(file_data_byte),.service_file_last(file_last),.owner_valid(),.owner());
    wire [3:0] human_index=ctrl_display_valid?ctrl_display_index+1'b1:0;
    assign playback_status={app_error,human_index,ctrl_interval,ctrl_auto,ctrl_display_valid,ctrl_busy,audio_active,1'b0};
    media_catalog #(.MAX_IMAGES(MAX_IMAGES)) catalog(
        .clk(clk),.rst(rst),.scan_start(scan_start),.list_done(scan_done),.list_error(scan_error),
        .entry_valid(entry_valid),.entry_ready(entry_ready),.entry_name(entry_name),.entry_kind(entry_kind),
        .entry_cluster(entry_cluster),.entry_size(entry_size),.catalog_done(catalog_done),.catalog_error(catalog_error),.overflow(),.image_count(image_count),
        .query_valid(catalog_query_valid),.query_ready(catalog_query_ready),.query_index(ctrl_load_index),
        .result_valid(catalog_result_valid),.result_ready(catalog_result_ready),.result_found(catalog_found),.audio_found(catalog_audio_found),
        .image_cluster(catalog_image_cluster),.audio_cluster(catalog_audio_cluster),.image_size(catalog_image_size),.audio_size(catalog_audio_size));
    media_playback_ctrl #(.CLK_FREQ_HZ(CLK_FREQ_HZ),.MAX_IMAGES(MAX_IMAGES),.TOKEN_BITS(TOKEN_BITS),
        .REQUEST_TIMEOUT_CYCLES(REQUEST_TIMEOUT_CYCLES),.LOAD_TIMEOUT_CYCLES(LOAD_TIMEOUT_CYCLES),.COMMIT_TIMEOUT_CYCLES(COMMIT_TIMEOUT_CYCLES)) controller(
        .clk(clk),.rst(rst),.restart(restart),.scan_done(scan_result_pending && !scan_result_error),
        .scan_error(scan_result_pending && scan_result_error),.scan_ready(ctrl_scan_ready),.image_count(image_count),.key_next(key_next),.key_auto(key_auto),
        .interval_sel(interval_sel),.load_req(ctrl_load_req),.load_accept(ctrl_load_accept),.load_index(ctrl_load_index),.load_buffer(ctrl_load_buffer),
        .load_token(ctrl_load_token),.load_cancel(ctrl_load_cancel),.cancel_flush_display(ctrl_cancel_flush),.cancel_ack(commit_cancel_ack),
        .frame_ready(ctrl_frame_ready),.frame_error(ctrl_frame_error),.frame_token(ctrl_frame_token),.commit_req(ctrl_commit_req),
        .commit_accept(ctrl_commit_accept && matching_started),.commit_token(ctrl_commit_token),.display_commit(ctrl_display_commit),.display_valid(ctrl_display_valid),
        .display_index(ctrl_display_index),.display_buffer(ctrl_display_buffer),.auto_play_en(ctrl_auto),.interval_sec(ctrl_interval),.error_code(ctrl_error),.busy(ctrl_busy));
    image_frame_loader #(.OUTPUT_WIDTH(OUTPUT_WIDTH),.OUTPUT_HEIGHT(OUTPUT_HEIGHT),.TOKEN_BITS(TOKEN_BITS),.BILINEAR_ENABLE(BILINEAR_ENABLE)) loader(
        .clk(clk),.rst(rst),.load_req(loader_load_req),.load_accept(loader_load_accept),.load_cluster(descriptor_cluster),.load_size(descriptor_size),.file_slot(target_slot),
        .load_bank(ctrl_load_buffer),.load_token(ctrl_load_token),.load_cancel(ctrl_load_cancel),.load_cancel_ack(loader_cancel_ack),
        .frame_ready(loader_frame_ready),.frame_error(loader_frame_error),.frame_token(loader_frame_token),.busy(loader_busy),.error_code(loader_error),
        .file_cmd_valid(loader_file_cmd_valid),.file_cmd_ready(loader_file_cmd_ready),.file_cmd_op(loader_file_cmd_op),.file_cmd_channel(loader_file_cmd_channel),.file_cmd_cluster(loader_file_cmd_cluster),.file_cmd_size(loader_file_cmd_size),
        .file_done(loader_file_done),.file_error(loader_file_error),.file_open_complete(loader_file_open_complete),.file_data_valid(loader_file_data_valid),.file_data_ready(loader_file_data_ready),.file_data_byte(loader_file_data_byte),.file_last(loader_file_last),.file_abort(loader_file_abort),.file_cancel_ack(loader_file_cancel_ack),
        .mem_begin_req(mem_begin_req),.mem_begin_accept(mem_begin_accept),.mem_bank(mem_bank),.mem_token(mem_token),.mem_write_valid(mem_write_valid),.mem_write_ready(mem_write_ready),.mem_write_address(mem_write_address),.mem_write_data(mem_write_data),.mem_flush_req(mem_flush_req),.mem_flush_ack(mem_flush_ack),.mem_error(mem_error),.mem_response_token(mem_response_token),.mem_cancel(mem_cancel),.mem_cancel_ack(mem_cancel_ack));
    media_audio_scene_manager #(.TOKEN_BITS(TOKEN_BITS),.PIXEL_HZ(PIXEL_HZ),.SAMPLE_HZ(SAMPLE_HZ),.FIFO_BITS(AUDIO_FIFO_BITS),
        .PRELOAD_SAMPLES(AUDIO_PRELOAD),.READ_RESERVE(AUDIO_READ_RESERVE)) audio(
        .clk(clk),.pixel_clk(pixel_clk),.rst(rst),.cancel_all(cancel_everything),.cancel_slot(cancel_audio),
        .cancel_ack(audio_cancel_ack),.available(audio_available),.prepared(audio_prepared),
        .prepare_valid(image_ready && !audio_requested && !ctrl_load_cancel && !restart),.prepare_slot(work_slot),
        .prepare_has_audio(audio_descriptor_valid),.prepare_token(work_token),.prepare_cluster(audio_descriptor_cluster),.prepare_size(audio_descriptor_size),.prepare_ready(audio_prepare_ready),
        .arm_valid(audio_requested && audio_prepared[work_slot] && !arm_requested && !ctrl_load_cancel && !restart),.arm_slot(work_slot),
        .arm_token(work_token),.cancel_scene(ctrl_load_cancel || restart),.arm_ready(scene_arm_ready),.armed(scene_armed),.scene_cancel_ack(scene_cancel_ack),
        .started(scene_started),.started_slot(scene_started_slot),.started_token(scene_started_token),.scene_error(scene_error),
        .current_valid(current_audio_valid),.current_slot(current_audio_slot),
        .video_sof(video_scene_sof),.video_scene_valid(video_scene_valid),.video_scene_token(video_scene_token),
        .file_cmd_valid(audio_file_cmd_valid),.file_cmd_ready(audio_file_cmd_ready),.file_cmd_op(audio_file_cmd_op),.file_cmd_channel(audio_file_cmd_channel),
        .file_cmd_cluster(audio_file_cmd_cluster),.file_cmd_size(audio_file_cmd_size),.file_done(arb_done[2:1]),.file_error(arb_error[2:1]),
        .file_open_complete(arb_complete[2:1]),.file_cancel_ack(arb_cancel_ack[2:1]),.file_data_ready(audio_file_data_ready),.file_data_valid(arb_data_valid[2:1]),
        .file_data_byte(arb_byte),.file_last(arb_last),.file_abort(audio_file_abort),.urgent(audio_urgent),
        .sample_valid(sample_valid),.sample_left(sample_left),.sample_right(sample_right),.sample_count(sample_count),
        .audio_active(audio_active),.audio_done(audio_done),.audio_error(audio_error),.audio_underflow(audio_underflow),.error_detail(audio_error_detail));
    video_frame_manager #(.TOKEN_BITS(TOKEN_BITS),.ENABLE_TRANSITION(ENABLE_TRANSITION)) frames(
        .clk(clk),.rst(rst),.frame_ready(ctrl_frame_ready),.frame_error(loader_frame_error),.frame_bank(ctrl_load_buffer),.frame_token(work_token),
        .commit_req(ctrl_commit_req),.commit_accept(ctrl_commit_accept),.commit_token(ctrl_commit_token),.cancel_flush_display(ctrl_cancel_flush),
        .frame_boundary(frame_boundary),.display_idle(display_idle),.fifo0_empty(fifo0_empty),.fifo1_empty(fifo1_empty),.display_locks(display_locks),
        .transition_done(transition_done),.scan_dual(scan_dual),.scan_next_bank(scan_next_bank),.session_reconfigure(session_reconfigure),
        .display_valid(display_valid),.display_bank(display_bank),.display_epoch(display_epoch),.scan_scene_token(scan_scene_token),.frame_response_token(),.frame_fault(),.cancel_ack(frame_cancel_ack));
    always @(posedge clk or posedge rst)begin
        if(rst)begin
            descriptor_valid<=0;descriptor_cluster<=0;descriptor_size<=0;
            audio_descriptor_valid<=0;audio_descriptor_cluster<=0;audio_descriptor_size<=0;
            image_ready<=0;audio_requested<=0;frame_published<=0;arm_requested<=0;matching_started<=0;work_slot<=0;work_token<=0;
            query_inflight<=0;catalog_done_seen<=0;scan_failed<=0;file_flush_req<=0;
            scan_result_pending<=0;scan_result_error<=0;
        end
        else begin
            if(restart)file_flush_req<=1;else if(file_flush_ack)file_flush_req<=0;
            catalog_done_seen<=catalog_done;
            if(scan_result_pending && ctrl_scan_ready)scan_result_pending<=0;
            if(scan_error || (catalog_done && !catalog_done_seen))begin
                scan_result_pending<=1;scan_result_error<=scan_error || catalog_error;
            end
            // restart丢弃旧代结果；本次重扫结果可在CANCEL期间保持至WAIT_SCAN接收。
            if(scan_start || restart)begin scan_result_pending<=0;scan_result_error<=0;end
            if(scan_start || restart)scan_failed<=0;
            else if(scan_error || catalog_error)scan_failed<=1;
            if(ctrl_load_req && work_token!=ctrl_load_token)begin
                work_slot<=target_slot;work_token<=ctrl_load_token;image_ready<=0;audio_requested<=0;
                frame_published<=0;arm_requested<=0;matching_started<=0;
            end
            if(loader_frame_ready)image_ready<=1;
            if(image_ready && !audio_requested && audio_prepare_ready && !ctrl_load_cancel && !restart)audio_requested<=1;
            if(audio_requested && audio_prepared[work_slot] && !arm_requested && scene_arm_ready && !ctrl_load_cancel && !restart)arm_requested<=1;
            if(ctrl_frame_ready)frame_published<=1;
            if(scene_started && scene_started_token==work_token && scene_started_slot==work_slot)matching_started<=1;
            if(ctrl_load_cancel || restart)begin image_ready<=0;audio_requested<=0;frame_published<=0;arm_requested<=0;matching_started<=0;end
            if(catalog_query_valid && catalog_query_ready)query_inflight<=1;
            if(catalog_result_valid && catalog_result_ready)begin
                query_inflight<=0;
                descriptor_valid<=catalog_found && ctrl_load_req && !ctrl_load_cancel && !restart;
                descriptor_cluster<=catalog_image_cluster;descriptor_size<=catalog_image_size;
                audio_descriptor_valid<=catalog_audio_found && ctrl_load_req && !ctrl_load_cancel && !restart;
                audio_descriptor_cluster<=catalog_audio_cluster;audio_descriptor_size<=catalog_audio_size;
            end
            if(ctrl_load_accept || ctrl_load_cancel || restart || scan_start)descriptor_valid<=0;
            if(scan_start || restart)begin
                query_inflight<=0;audio_descriptor_valid<=0;
            end
            if(scan_start)catalog_done_seen<=0;
        end
    end
endmodule
