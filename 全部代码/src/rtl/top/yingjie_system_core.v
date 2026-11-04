`timescale 1ns/1ps
// 映界应用系统核心：外部时钟由最终PLL/顶层提供，模块内部完成存储、图片、显示和音频边界连接。
// 本核心不包含参考工程的I2S播放、BMP物理扫描或整体frame_fifo架构；HDMI协议由供应商Core边界完成。
module yingjie_system_core #(
    parameter integer CLK_FREQ_HZ=100_000_000,
    parameter integer OUTPUT_WIDTH=1280,OUTPUT_HEIGHT=720,
    parameter integer BILINEAR_ENABLE=0,
    parameter integer SPECTRUM_VISUAL_ENABLE=BILINEAR_ENABLE
)(
    input wire ctrl_clk,mem_clk,pixel_clk,rst,restart,
    input wire key_next,key_auto,
    input wire [1:0] interval_sel,
    input wire sdram_phy_clk,sdram_capture_clk,
    input wire sd_miso,
    output wire sd_cs_n,sd_sclk,sd_mosi,
    input wire edid_start,
    input wire osd_enable,
    input wire subtitle_enable,
    input wire [127:0] subtitle_text,
    input wire [23:0] subtitle_color,
    input wire signed [8:0] brightness,
    input wire [7:0] contrast,
    input wire spectrum_enable,menu_open,
    input wire [2:0] menu_item,
    output wire [9:0] tmds0,tmds1,tmds2,tmds_clock,
    output wire edid_valid,
    output wire [7:0] edid_data,
    output wire ddc_scl,
    inout wire ddc_sda,
    output wire app_busy,
    output wire [3:0] app_error,
    output wire video_underflow,
    output wire video_fault,
    output wire audio_underflow,
    output wire hdmi_locked,spectrum_overrun
);
    localparam [20:0] FRAME_WORDS=OUTPUT_WIDTH*OUTPUT_HEIGHT;
    wire scan_start,scan_done,scan_error,entry_valid,entry_ready;
    wire [87:0] entry_name;wire [1:0] entry_kind;wire [27:0] entry_cluster;wire [31:0] entry_size;
    wire file_cmd_valid,file_cmd_ready,file_cmd_channel,file_done,file_error,file_cancel_ack,file_abort;
    wire [2:0] file_cmd_op;wire [27:0] file_cmd_cluster;wire [31:0] file_cmd_size;
    wire file_open_complete;
    wire file_data_valid,file_data_ready,file_last;wire [7:0] file_data_byte;
    wire init_done,high_capacity,init_error;wire [3:0] sd_error_code;
    wire [1:0] display_locks;wire display_valid,display_bank,commit_pending,display_cancel;
    wire [7:0] display_epoch;
    wire [7:0] scan_scene_token,scan_pixel_scene_token,pipeline_scene_token,hdmi_scene_token;
    wire pipeline_scene_valid,hdmi_scene_sof,hdmi_scene_valid;
    wire scan_dual,scan_next_bank,session_reconfigure,transition_done;
    wire [7:0] transition_alpha;
    wire [15:0] playback_status;
    wire frame_boundary,display_idle,fifo0_empty,fifo1_empty;
    wire mem_begin_req,mem_begin_accept,mem_bank,mem_write_valid,mem_write_ready,mem_flush_req,mem_flush_ack,mem_error,mem_cancel,mem_cancel_ack;
    wire [7:0] mem_token,mem_response_token;wire [20:0] mem_write_address;wire [31:0] mem_write_data;
    wire store_begin_req,store_begin_accept,store_bank,store_write_valid,store_write_ready;
    wire store_flush_req,store_flush_ack,store_error,store_cancel,store_cancel_ack;
    wire [7:0] store_token;wire [20:0] store_write_address;wire [31:0] store_write_data;
    wire [1:0] scan_locks;
    wire read_req,read_accept,read_valid,read_last,read_done,read_error;wire [20:0] read_address;wire [8:0] read_length;wire [31:0] read_data;
    wire cmd_valid,cmd_ready,cmd_write,wr_valid,wr_ready,backend_rd_valid,backend_rd_last,backend_rd_ready,backend_done,backend_error,backend_abort,backend_cancel_ack;
    wire [31:0] backend_rd_data;
    wire [20:0] cmd_addr;wire [8:0] cmd_len;wire [31:0] wr_data;wire [3:0] wr_mask;
    wire init_mem_done,busy_mem;wire [31:0] refresh_count,command_count;
    wire scanout_start_ready,scanout_stop_ack,scanout_active,scanout_error,scanout_underflow;
    wire [23:0] scan_rgb0,scan_rgb1;wire [10:0] scan_x,scan_y;wire scan_de,scan_hs,scan_vs,scan_valid;
    wire [12:0] scan_fifo0,scan_fifo1;
    wire scan_start_pulse,scan_stop_pulse,pixel_frame_boundary,pixel_rst,line_fault;
    wire memory_rst,scan_start_mem,scan_stop_mem,scan_dual_mem,scan_bank_mem,scan_next_bank_mem;
    wire [7:0] scan_scene_token_mem;
    wire scan_ready_mem,scan_stop_ack_mem,scan_error_mem,scan_underflow_mem,transition_done_mem;
    (* async_reg="true" *) reg line_fault_meta,line_fault_sync;
    wire pipeline_de,pipeline_hs,pipeline_vs;wire [10:0] pipeline_x,pipeline_y;wire [23:0] pipeline_rgb;
    wire sample_valid;wire signed [15:0] sample_left,sample_right;wire [31:0] sample_count;
    wire app_audio_active,app_audio_done,app_audio_error;
    wire hdmi_rst;
    assign app_busy=commit_pending || !init_done || !display_valid;
    assign video_underflow=scanout_underflow;
    assign video_fault=scanout_error || line_fault_sync;
    reset_sync memory_reset(.clk(mem_clk),.rst_in(rst),.rst_out(memory_rst));
    reset_sync pixel_reset(.clk(pixel_clk),.rst_in(rst),.rst_out(pixel_rst));
    reset_sync transport_reset(.clk(pixel_clk),.rst_in(rst || restart || display_cancel),.rst_out(hdmi_rst));
    always @(posedge ctrl_clk or posedge rst)begin
        if(rst)begin line_fault_meta<=0;line_fault_sync<=0;end
        else begin line_fault_meta<=line_fault;line_fault_sync<=line_fault_meta;end
    end
    media_sd_startup #(.CLK_FREQ_HZ(CLK_FREQ_HZ)) storage(
        .clk(ctrl_clk),.rst(rst),.restart(restart),.scan_start(scan_start),.scan_done(scan_done),.scan_error(scan_error),
        .entry_valid(entry_valid),.entry_ready(entry_ready),.entry_name(entry_name),.entry_kind(entry_kind),.entry_cluster(entry_cluster),.entry_size(entry_size),
        .app_cmd_valid(file_cmd_valid),.app_cmd_ready(file_cmd_ready),.app_cmd_op(file_cmd_op),.app_cmd_channel(file_cmd_channel),.app_cmd_cluster(file_cmd_cluster),.app_cmd_size(file_cmd_size),
        .app_done(file_done),.app_error(file_error),.app_open_complete(file_open_complete),.app_cancel_ack(file_cancel_ack),.app_abort(file_abort),.app_data_valid(file_data_valid),.app_data_ready(file_data_ready),.app_data_byte(file_data_byte),.app_file_last(file_last),
        .sd_cs_n(sd_cs_n),.sd_sclk(sd_sclk),.sd_mosi(sd_mosi),.sd_miso(sd_miso),.init_done(init_done),.high_capacity(high_capacity),.init_error(init_error),.sd_error_code(sd_error_code),.error_detail(),.error_r1());
    media_application_core #(.CLK_FREQ_HZ(CLK_FREQ_HZ),.OUTPUT_WIDTH(OUTPUT_WIDTH),.OUTPUT_HEIGHT(OUTPUT_HEIGHT),.ENABLE_TRANSITION(1),.BILINEAR_ENABLE(BILINEAR_ENABLE)) application(
        .clk(ctrl_clk),.pixel_clk(pixel_clk),.rst(rst),.restart(restart),.scan_start(scan_start),.scan_done(scan_done),.scan_error(scan_error),
        .video_scene_sof(hdmi_scene_sof),.video_scene_valid(hdmi_scene_valid),.video_scene_token(hdmi_scene_token),
        .entry_valid(entry_valid),.entry_ready(entry_ready),.entry_name(entry_name),.entry_kind(entry_kind),.entry_cluster(entry_cluster),.entry_size(entry_size),
        .key_next(key_next),.key_auto(key_auto),.interval_sel(interval_sel),.display_locks(display_locks),.frame_boundary(frame_boundary),.display_idle(display_idle),.fifo0_empty(fifo0_empty),.fifo1_empty(fifo1_empty),
        .display_valid(display_valid),.display_bank(display_bank),.display_epoch(display_epoch),.scan_scene_token(scan_scene_token),.commit_pending(commit_pending),.display_cancel(display_cancel),.app_error(app_error),.playback_status(playback_status),.error_detail(),
        .transition_done(transition_done),.display_error(scanout_error || scanout_underflow || line_fault_sync),
        .scan_dual(scan_dual),.scan_next_bank(scan_next_bank),.session_reconfigure(session_reconfigure),
        .audio_active(app_audio_active),.audio_done(app_audio_done),.audio_error(app_audio_error),.audio_underflow(audio_underflow),
        .sample_valid(sample_valid),.sample_left(sample_left),.sample_right(sample_right),.sample_count(sample_count),
        .file_cmd_valid(file_cmd_valid),.file_cmd_ready(file_cmd_ready),.file_cmd_op(file_cmd_op),.file_cmd_channel(file_cmd_channel),.file_cmd_cluster(file_cmd_cluster),.file_cmd_size(file_cmd_size),
        .file_done(file_done),.file_error(file_error),.file_open_complete(file_open_complete),.file_data_valid(file_data_valid),.file_data_ready(file_data_ready),.file_data_byte(file_data_byte),.file_last(file_last),.file_abort(file_abort),.file_cancel_ack(file_cancel_ack),
        .mem_begin_req(mem_begin_req),.mem_begin_accept(mem_begin_accept),.mem_bank(mem_bank),.mem_token(mem_token),.mem_write_valid(mem_write_valid),.mem_write_ready(mem_write_ready),.mem_write_address(mem_write_address),.mem_write_data(mem_write_data),.mem_flush_req(mem_flush_req),.mem_flush_ack(mem_flush_ack),.mem_error(mem_error),.mem_response_token(mem_response_token),.mem_cancel(mem_cancel),.mem_cancel_ack(mem_cancel_ack));
    frame_write_cdc writes(.src_clk(ctrl_clk),.dst_clk(mem_clk),.rst(rst),
        .src_begin_req(mem_begin_req),.src_begin_accept(mem_begin_accept),.src_bank(mem_bank),.src_token(mem_token),
        .src_write_valid(mem_write_valid),.src_write_ready(mem_write_ready),.src_write_address(mem_write_address),.src_write_data(mem_write_data),
        .src_flush_req(mem_flush_req),.src_flush_ack(mem_flush_ack),.src_cancel(mem_cancel),.src_cancel_ack(mem_cancel_ack),.src_error(mem_error),.src_response_token(mem_response_token),
        .dst_begin_req(store_begin_req),.dst_begin_accept(store_begin_accept),.dst_bank(store_bank),.dst_token(store_token),
        .dst_write_valid(store_write_valid),.dst_write_ready(store_write_ready),.dst_write_address(store_write_address),.dst_write_data(store_write_data),
        .dst_flush_req(store_flush_req),.dst_flush_ack(store_flush_ack),.dst_cancel(store_cancel),.dst_cancel_ack(store_cancel_ack),.dst_error(store_error));
    frame_store_adapter #(.FRAME_WORDS(OUTPUT_WIDTH*OUTPUT_HEIGHT)) frames(
        .clk(mem_clk),.rst(memory_rst),.mem_begin_req(store_begin_req),.mem_begin_accept(store_begin_accept),.mem_bank(store_bank),.mem_token(store_token),.display_locks(scan_locks),
        .mem_write_valid(store_write_valid),.mem_write_ready(store_write_ready),.mem_write_address(store_write_address),.mem_write_data(store_write_data),.mem_flush_req(store_flush_req),.mem_flush_ack(store_flush_ack),.mem_error(store_error),.mem_response_token(),.mem_cancel(store_cancel),.mem_cancel_ack(store_cancel_ack),.writer_active(),
        .read_req(read_req),.read_accept(read_accept),.read_address(read_address),.read_length(read_length),.read_valid(read_valid),.read_ready(1'b1),.read_data(read_data),.read_last(read_last),.read_done(read_done),.read_error(read_error),
        .cmd_valid(cmd_valid),.cmd_ready(cmd_ready),.cmd_write(cmd_write),.cmd_addr(cmd_addr),.cmd_len(cmd_len),.wr_valid(wr_valid),.wr_ready(wr_ready),.wr_data(wr_data),.wr_mask(wr_mask),.backend_rd_valid(backend_rd_valid),.backend_rd_last(backend_rd_last),.backend_rd_data(backend_rd_data),.backend_rd_ready(backend_rd_ready),.backend_done(backend_done),.backend_error(backend_error),.backend_abort(backend_abort),.backend_cancel_ack(backend_cancel_ack));
    eg4s20_sdram_backend memory(.clk(mem_clk),.sdram_phy_clk(sdram_phy_clk),.sdram_capture_clk(sdram_capture_clk),.rst(memory_rst),.cmd_valid(cmd_valid),.cmd_ready(cmd_ready),.cmd_write(cmd_write),.cmd_addr(cmd_addr),.cmd_len(cmd_len),.wr_valid(wr_valid),.wr_ready(wr_ready),.wr_data(wr_data),.wr_mask(wr_mask),.rd_valid(backend_rd_valid),.rd_last(backend_rd_last),.rd_data(backend_rd_data),.rd_ready(backend_rd_ready),.done(backend_done),.error(backend_error),.error_code(),.abort(backend_abort),.cancel_ack(backend_cancel_ack),.init_done(init_mem_done),.busy(busy_mem));
    assign fifo0_empty=display_idle;assign fifo1_empty=display_idle;
    video_session_ctrl sessions(.clk(ctrl_clk),.pixel_clk(pixel_clk),.rst(rst),.display_valid(display_valid),
        .display_epoch(display_epoch),.commit_pending(session_reconfigure),.display_cancel(display_cancel),
        .pixel_frame_boundary(pixel_frame_boundary),.start_ready(scanout_start_ready),.stop_ack(scanout_stop_ack),
        .start(scan_start_pulse),.stop(scan_stop_pulse),.drained(display_idle),.frame_boundary(frame_boundary));
    video_session_cdc session_bridge(.src_clk(ctrl_clk),.dst_clk(mem_clk),.rst(rst),
        .src_start(scan_start_pulse),.src_stop(scan_stop_pulse),.src_dual(scan_dual),.src_bank(display_bank),.src_next_bank(scan_next_bank),.src_scene_token(scan_scene_token),
        .src_start_ready(scanout_start_ready),.src_stop_ack(scanout_stop_ack),.src_error(scanout_error),.src_underflow(scanout_underflow),.src_transition_done(transition_done),
        .dst_start(scan_start_mem),.dst_stop(scan_stop_mem),.dst_dual(scan_dual_mem),.dst_bank(scan_bank_mem),.dst_next_bank(scan_next_bank_mem),.dst_scene_token(scan_scene_token_mem),.dst_locks(scan_locks),
        .dst_start_ready(scan_ready_mem),.dst_stop_ack(scan_stop_ack_mem),.dst_error(scan_error_mem),.dst_underflow(scan_underflow_mem),.dst_transition_done(transition_done_mem));
    video_scanout_stream scanout(.clk(mem_clk),.pixel_clk(pixel_clk),.rst(memory_rst),.start(scan_start_mem),.stop(scan_stop_mem),.dual_frames(scan_dual_mem),.base0(scan_bank_mem?FRAME_WORDS:21'd0),.base1(scan_next_bank_mem?FRAME_WORDS:21'd0),.start_scene_token(scan_scene_token_mem),.pixel_scene_token(scan_pixel_scene_token),.start_ready(scan_ready_mem),.stop_ack(scan_stop_ack_mem),.active(scanout_active),.error(scan_error_mem),.underflow(scan_underflow_mem),.rgb0(scan_rgb0),.rgb1(scan_rgb1),.x(scan_x),.y(scan_y),.de(scan_de),.hsync(scan_hs),.vsync(scan_vs),.pixel_valid(scan_valid),.frame_boundary(pixel_frame_boundary),.transition_alpha(transition_alpha),.transition_done(transition_done_mem),.fifo0_level(scan_fifo0),.fifo1_level(scan_fifo1),.read_req(read_req),.read_accept(read_accept),.read_valid(read_valid),.read_last(read_last),.read_done(read_done),.read_error(read_error),.read_address(read_address),.read_length(read_length),.read_data(read_data));
    video_presentation #(.SPECTRUM_VISUAL_ENABLE(SPECTRUM_VISUAL_ENABLE)) presentation(.mem_clk(ctrl_clk),.pixel_clk(pixel_clk),.rst(rst),.frame_start(pixel_frame_boundary),
        .de_in(scan_de),.hs_in(scan_hs),.vs_in(scan_vs),.x_in(scan_x),.y_in(scan_y),.rgb0(scan_rgb0),.rgb1(scan_rgb1),.alpha(transition_alpha),
        .scene_valid_in(scan_valid),.scene_token_in(scan_pixel_scene_token),.scene_valid_out(pipeline_scene_valid),.scene_token_out(pipeline_scene_token),
        .osd_enable(osd_enable),.subtitle_enable(subtitle_enable),.subtitle_text(subtitle_text),.subtitle_color(subtitle_color),
        .brightness(brightness),.contrast(contrast),.spectrum_enable(spectrum_enable),.menu_open(menu_open),.menu_item(menu_item),
        .interval_sel(interval_sel),.playback_status(playback_status),.sample_valid(sample_valid),.sample_left(sample_left),.sample_right(sample_right),
        .spectrum_overrun(spectrum_overrun),.de_out(pipeline_de),.hs_out(pipeline_hs),.vs_out(pipeline_vs),.x_out(pipeline_x),.y_out(pipeline_y),.rgb_out(pipeline_rgb));
    hdmi_av_output hdmi(.clk(pixel_clk),.rst(hdmi_rst),.pixel_valid(pipeline_de),.x(pipeline_x),.y(pipeline_y),.pixel_rgb(pipeline_rgb),
        .scene_valid(pipeline_scene_valid),.scene_token(pipeline_scene_token),.scene_sof(hdmi_scene_sof),.scene_sof_valid(hdmi_scene_valid),.scene_sof_token(hdmi_scene_token),
        .sample_valid(sample_valid),.sample_left(sample_left),.sample_right(sample_right),.edid_start(edid_start),.edid_valid(edid_valid),.edid_data(edid_data),.line_fault(line_fault),.video_locked(hdmi_locked),.ddc_scl(ddc_scl),.ddc_sda(ddc_sda),.tmds0(tmds0),.tmds1(tmds1),.tmds2(tmds2),.tmds_clock(tmds_clock));
endmodule
