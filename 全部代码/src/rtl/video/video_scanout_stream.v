`timescale 1ns/1ps
// 两帧持续预取与720p扫描。clk为存储域，pixel_clk为74.25MHz。
// start/stop/base/dual_frames属于clk域；active/RGB/同步/level属于pixel_clk域。
// 每次session配置保持到stop_ack，像素端在完整预充后帧首启播。
module video_scanout_stream #(
    parameter integer PRELOAD_WORDS=3072,WIDTH=1280,HEIGHT=720,
    parameter integer H_FRONT=110,H_SYNC=40,H_BACK=220,V_FRONT=5,V_SYNC=5,V_BACK=20
)(
    input wire clk,pixel_clk,rst,start,stop,dual_frames,
    input wire [20:0] base0,base1,
    input wire [7:0] start_scene_token,
    output reg [7:0] pixel_scene_token,
    output wire start_ready,stop_ack,
    output wire active,
    output reg error,underflow,
    output wire [23:0] rgb0,rgb1,
    output reg [10:0] x,y,
    output reg de,hsync,vsync,pixel_valid,
    output wire frame_boundary,
    output wire [7:0] transition_alpha,
    output wire transition_done,
    output wire [12:0] fifo0_level,fifo1_level,
    output wire read_req,
    input wire read_accept,read_valid,read_last,read_done,read_error,
    output wire [20:0] read_address,
    output wire [8:0] read_length,
    input wire [31:0] read_data
);
    localparam OFF=0,RUN=1,DRAIN=2,CLEAR=3;
    localparam [20:0] FRAME_WORDS=WIDTH*HEIGHT;
    reg [1:0] state;
    reg [3:0] clear_count;
    reg stop_requested,config_dual;
    reg [20:0] config_base0,config_base1;
    reg [7:0] config_scene_token;
    reg pf_start;
    wire pf_running,pf_done,pf_error;
    wire write0,write1,ready0,ready1,empty0,empty1,valid0,valid1;
    wire [23:0] data0,data1,out0,out1;
    wire [12:0] used0,used1;
    reg clear_asserted;
    wire fifo_reset=rst || clear_asserted;
    wire pixel_rst,stream_rst;
    wire run_requested=state==RUN && !stop_requested;
    (* async_reg="true" *) reg run_meta,run_sync,active_meta,active_sync,fault_meta,fault_sync,dual_meta;
    reg stop_toggle,pixel_stopped;
    (* async_reg="true" *) reg stop_meta,stop_sync,stopped_meta,stopped_sync;
    reg pixel_active,pixel_fault,dual_pixel;
    wire stop_confirmed=stopped_sync==stop_toggle;
    wire pf_stop=state==DRAIN && stop_confirmed;
    wire keep_prefetch=state==RUN || (state==DRAIN && !stop_confirmed);
    wire [10:0] raw_x,raw_y;
    wire raw_de,raw_hs,raw_vs,line_start,frame_start,vblank_start;
    wire prefilled=fifo0_level>=PRELOAD_WORDS && (!dual_pixel || fifo1_level>=PRELOAD_WORDS);
    wire begin_frame=frame_start && run_sync && prefilled && !pixel_fault;
    wire show_pixel=(pixel_active || begin_frame) && raw_de && !pixel_fault;
    wire fifo_pair_ready=!empty0 && (!dual_pixel || !empty1);
    wire take=show_pixel && fifo_pair_ready;
    reg transition_started,transition_complete;
    wire blend_active,blend_done;
    wire [7:0] blend_alpha;
    (* async_reg="true" *) reg transition_meta,transition_sync;
    wire visible_frame_start=frame_start && take && !stream_rst;
    assign transition_alpha=dual_pixel?blend_alpha:8'd0;
    assign transition_done=transition_sync;
    video_transition_ctrl transition(.clk(pixel_clk),.rst(stream_rst),
        .start(run_sync && dual_pixel && !transition_started),.frame_start(visible_frame_start),
        .active(blend_active),.alpha(blend_alpha),.done(blend_done));
    always @(posedge pixel_clk or posedge stream_rst)begin
        if(stream_rst)begin transition_started<=0;transition_complete<=0;end
        else begin
            if(run_sync && dual_pixel)transition_started<=1;
            if(blend_done)transition_complete<=1;
        end
    end
    assign active=pixel_active;
    assign frame_boundary=frame_start;
    assign start_ready=state==OFF && !stop && !rst;
    assign stop_ack=state==OFF && stop;
    // session配置在停止排空后写入，经run握手/预充后帧首捕获，token与首像素同拍公开。
    always @(posedge pixel_clk)if(begin_frame)pixel_scene_token<=config_scene_token;
    assign rgb0=pixel_valid?out0:24'b0;
    assign rgb1=pixel_valid && dual_pixel?out1:24'b0;
    reset_sync pixel_reset(.clk(pixel_clk),.rst_in(rst),.rst_out(pixel_rst));
    reset_sync #(.RELEASE_NEGEDGE(1)) stream_reset(.clk(pixel_clk),.rst_in(fifo_reset),.rst_out(stream_rst));
    video_timing_720p #(.WIDTH(WIDTH),.HEIGHT(HEIGHT),.H_FRONT(H_FRONT),.H_SYNC(H_SYNC),.H_BACK(H_BACK),
        .V_FRONT(V_FRONT),.V_SYNC(V_SYNC),.V_BACK(V_BACK)) timing(.pixel_clk(pixel_clk),.rst(pixel_rst),.x(raw_x),.y(raw_y),.de(raw_de),
        .hsync(raw_hs),.vsync(raw_vs),.line_start(line_start),.frame_start(frame_start),.vblank_start(vblank_start));
    video_burst_prefetch prefetch(.clk(clk),.rst(fifo_reset),.start(pf_start),.stop(pf_stop),
        .lane0_enable(1'b1),.lane1_enable(config_dual),.lane0_base(config_base0),.lane1_base(config_base1),
        .frame_words(FRAME_WORDS),.fifo0_used(used0),.fifo1_used(used1),.fifo0_ready(ready0),.fifo1_ready(ready1),
        .fifo0_wr_valid(write0),.fifo0_wr_data(data0),.fifo1_wr_valid(write1),.fifo1_wr_data(data1),
        .read_req(read_req),.read_accept(read_accept),.read_address(read_address),.read_length(read_length),
        .read_valid(read_valid),.read_last(read_last),.read_done(read_done),.read_error(read_error),.read_data(read_data),
        .running(pf_running),.done(pf_done),.error(pf_error));
    rgb_async_fifo fifo0(.wr_clk(clk),.rd_clk(pixel_clk),.rst(fifo_reset),.wr_valid(write0),.wr_data(data0),
        .wr_ready(ready0),.wr_used(used0),.rd_en(take),.rd_empty(empty0),.rd_valid(valid0),.rd_data(out0),.rd_used(fifo0_level));
    rgb_async_fifo fifo1(.wr_clk(clk),.rd_clk(pixel_clk),.rst(fifo_reset),.wr_valid(write1),.wr_data(data1),
        .wr_ready(ready1),.wr_used(used1),.rd_en(take && dual_pixel),.rd_empty(empty1),.rd_valid(valid1),.rd_data(out1),.rd_used(fifo1_level));
    always @(posedge pixel_clk or posedge pixel_rst)begin
        if(pixel_rst)begin x<=0;y<=0;de<=0;hsync<=0;vsync<=0;pixel_valid<=0;end
        else begin
            x<=raw_x;y<=raw_y;de<=raw_de;hsync<=raw_hs;vsync<=raw_vs;
            pixel_valid<=take && !stream_rst;
        end
    end
    always @(posedge pixel_clk or posedge stream_rst)begin
        if(stream_rst)begin run_meta<=0;run_sync<=0;pixel_active<=0;pixel_fault<=0;dual_pixel<=0;dual_meta<=0;end
        else begin
            run_meta<=run_requested;run_sync<=run_meta;
            dual_meta<=config_dual;dual_pixel<=dual_meta;
            if(begin_frame)pixel_active<=1;
            if(vblank_start && !run_sync)pixel_active<=0;
            if(show_pixel && !fifo_pair_ready)begin pixel_fault<=1;pixel_active<=0;end
        end
    end
    // 停机用来回toggle应答，不能把尚未同步的active=0误认作像素域已停止。
    always @(posedge pixel_clk or posedge pixel_rst)begin
        if(pixel_rst)begin stop_meta<=0;stop_sync<=0;pixel_stopped<=0;end
        else begin
            stop_meta<=stop_toggle;stop_sync<=stop_meta;
            if(!run_sync && !pixel_active)pixel_stopped<=stop_sync;
        end
    end
    always @(posedge clk or posedge rst)begin
        if(rst)begin
            state<=OFF;stop_requested<=0;config_dual<=0;config_base0<=0;config_base1<=0;config_scene_token<=0;
            error<=0;underflow<=0;pf_start<=0;clear_count<=0;clear_asserted<=1;
            active_meta<=0;active_sync<=0;fault_meta<=0;fault_sync<=0;
            stop_toggle<=0;stopped_meta<=0;stopped_sync<=0;
            transition_meta<=0;transition_sync<=0;
        end else begin
            active_meta<=pixel_active;active_sync<=active_meta;fault_meta<=pixel_fault;fault_sync<=fault_meta;
            stopped_meta<=pixel_stopped;stopped_sync<=stopped_meta;
            transition_meta<=transition_complete;transition_sync<=transition_meta;
            pf_start<=0;
            if(stop)stop_requested<=1;
            if(keep_prefetch && !pf_running && !pf_start && !pf_done && !pf_error)pf_start<=1;
            case(state)
                OFF:if(start && start_ready)begin
                    config_dual<=dual_frames;config_base0<=base0;config_base1<=base1;
                    config_scene_token<=start_scene_token;
                    stop_requested<=0;error<=0;underflow<=0;state<=RUN;clear_asserted<=0;
                end
                RUN:if(stop || stop_requested || fault_sync || pf_error)begin
                    state<=DRAIN;stop_toggle<=~stop_toggle;
                    if(fault_sync)underflow<=1;
                    if(pf_error)error<=1;
                end
                DRAIN:if(stop_confirmed && !pf_running && !pf_start)begin clear_count<=0;state<=CLEAR;clear_asserted<=1;end
                CLEAR:if(clear_count==7)begin state<=stop_requested?OFF:RUN;clear_asserted<=stop_requested;end
                      else clear_count<=clear_count+1'b1;
            endcase
        end
    end
endmodule
