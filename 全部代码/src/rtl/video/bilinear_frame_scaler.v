`timescale 1ns/1ps
// 加载端双行Q8双线性缩放候选；与nearest相同帧写接口，暂不接生产链。
module bilinear_frame_scaler #(
    parameter integer OUTPUT_WIDTH=1280,OUTPUT_HEIGHT=720,
    parameter integer MAX_SOURCE_WIDTH=1920,MAX_SOURCE_HEIGHT=1080
)(
    input wire clk,rst,start,abort,
    input wire [15:0] source_width,source_height,
    input wire bottom_up,source_done,
    input wire pixel_valid,
    output wire pixel_ready,
    input wire [23:0] pixel_rgb,
    input wire [15:0] pixel_x,pixel_y,
    output wire write_valid,
    input wire write_ready,
    output wire [20:0] write_address,
    output wire [31:0] write_data,
    output wire busy,
    output reg done,error,
    output reg [3:0] error_code
);
    localparam IDLE=0,GEOMETRY=1,GEOMETRY_WAIT=2,CLEAR=3,Y_BEGIN=4,Y_INTEGER_WAIT=5,
        Y_FRACTION_WAIT=6,PAIR_READY=7,RECEIVE=8,ADVANCE_SOURCE=9,FETCH_LEFT=10,
        CAPTURE_LEFT=11,CAPTURE_RIGHT=12,INTERPOLATE=13,SEND=14,NEXT_ROW=15,
        DRAIN=16,FINISHED=17,FAILED=18,PREPARE_X=19;
    localparam integer SOURCE_LIMIT=(MAX_SOURCE_WIDTH>0 && MAX_SOURCE_WIDTH<=65535)?MAX_SOURCE_WIDTH:1920;
    localparam integer LINE_BITS=SOURCE_LIMIT<2?1:$clog2(SOURCE_LIMIT);
    localparam integer X_FIXED_BITS=$clog2(SOURCE_LIMIT*256+1);
    localparam integer SOURCE_HEIGHT_LIMIT=(MAX_SOURCE_HEIGHT>0 && MAX_SOURCE_HEIGHT<=65535)?MAX_SOURCE_HEIGHT:1080;
    // 尺寸值本身也要可表示：2的幂上限使用clog2(limit+1)，坐标范围在start时校验。
    localparam integer SOURCE_X_BITS=$clog2(SOURCE_LIMIT+1),SOURCE_Y_BITS=$clog2(SOURCE_HEIGHT_LIMIT+1);
    localparam integer TARGET_WIDTH_LIMIT=(OUTPUT_WIDTH>0 && OUTPUT_WIDTH<=65535)?OUTPUT_WIDTH:1280;
    localparam integer TARGET_HEIGHT_LIMIT=(OUTPUT_HEIGHT>0 && OUTPUT_HEIGHT<=65535)?OUTPUT_HEIGHT:720;
    localparam integer TARGET_X_BITS=$clog2(TARGET_WIDTH_LIMIT+1),TARGET_Y_BITS=$clog2(TARGET_HEIGHT_LIMIT+1);
    localparam [63:0] FRAME_WORDS=64'd1*OUTPUT_WIDTH*OUTPUT_HEIGHT;
    localparam [20:0] ROW_FORWARD_STEP=OUTPUT_WIDTH,ROW_REVERSE_STEP=21'd0-ROW_FORWARD_STEP;
    reg [4:0] state;
    reg [SOURCE_X_BITS-1:0] sw,last_source_x,input_x;
    reg [SOURCE_Y_BITS-1:0] sh,last_source_y,source_row,map_y0,map_y1;
    wire [SOURCE_Y_BITS-1:0] latest_y=source_row;
    reg [TARGET_X_BITS-1:0] fit_w,off_x,target_x;
    reg [TARGET_Y_BITS-1:0] fit_h,off_y,target_y;
    reg reverse_rows,have_row,width_limited,geometry_phase;
    reg [31:0] width_product,height_product;
    reg [X_FIXED_BITS-1:0] x_fixed,x_step;
    reg [TARGET_X_BITS-1:0] x_error,x_step_remainder;
    reg [7:0] fraction_y;
    reg [20:0] clear_address,generic_row_address;
    wire [20:0] row_address=OUTPUT_WIDTH==1280?clear_address:generic_row_address;
    reg [23:0] p00,p01;
    (* ram_style="bram_32k" *) reg [23:0] even_line[0:(1<<LINE_BITS)-1];
    (* ram_style="bram_32k" *) reg [23:0] odd_line[0:(1<<LINE_BITS)-1];
    reg [23:0] even_pixel,odd_pixel;
    reg [LINE_BITS-1:0] left_address,right_address;
    reg div_start;
    reg [31:0] numerator,denominator;
    wire div_done,div_error;
    wire [31:0] quotient,remainder;
    wire [15:0] raw_x=x_fixed>>8;
    wire [15:0] left_x=raw_x>=last_source_x?last_source_x:raw_x;
    wire [15:0] right_x=left_x==last_source_x?left_x:left_x+1'b1;
    wire [7:0] fraction_x=x_fixed[7:0];
    wire [16:0] next_error={1'b0,x_error}+{1'b0,x_step_remainder};
    wire x_carry=next_error>={1'b0,fit_w};
    wire [15:0] needed_latest=reverse_rows?map_y0:map_y1;
    wire source_last=reverse_rows?source_row==0:source_row==last_source_y;
    wire target_last=reverse_rows?target_y==0:target_y==fit_h-1'b1;
    wire [LINE_BITS-1:0] memory_x=state==FETCH_LEFT?left_address:right_address;
    wire coordinates_match=pixel_x==input_x && pixel_y==source_row;
    wire interpolation_ready,interpolation_valid;
    wire [23:0] interpolation_rgb;
    wire [23:0] p10=map_y0[0]?odd_pixel:even_pixel;
    wire [23:0] p11=map_y1[0]?odd_pixel:even_pixel;
    wire [20:0] cursor_step=state==CLEAR?21'd1:(reverse_rows?ROW_REVERSE_STEP:ROW_FORWARD_STEP);
    wire [20:0] stepped_cursor=clear_address+cursor_step;
    wire [31:0] first_row_sum={{(32-TARGET_Y_BITS){1'b0}},off_y}+{{(32-TARGET_Y_BITS){1'b0}},target_y};
    wire [20:0] first_row_address=(numerator<<10)+(numerator<<8)+{{(21-TARGET_X_BITS){1'b0}},off_x};
    unsigned_divider divide(.clk(clk),.rst(rst),.abort(abort),.start(div_start),
        .dividend(numerator),.divisor(denominator),.busy(),.done(div_done),.error(div_error),
        .quotient(quotient),.remainder(remainder));
    bilinear_rgb_interpolator #(.LATCH_INPUTS(0)) interpolate(.clk(clk),.rst(rst),.abort(abort),
        .in_valid(state==INTERPOLATE),.in_ready(interpolation_ready),
        .p00(p00),.p10(p10),.p01(p01),.p11(p11),.fraction_x(fraction_x),.fraction_y(fraction_y),
        .out_valid(interpolation_valid),.out_ready(state==SEND && write_ready),.out_rgb(interpolation_rgb));
    assign busy=state!=IDLE && state!=FINISHED && state!=FAILED;
    assign pixel_ready=(state==RECEIVE || state==DRAIN) && !abort;
    assign write_valid=(state==CLEAR || (state==SEND && interpolation_valid)) && !rst && !abort;
    assign write_address=state==CLEAR?clear_address:row_address+target_x;
    assign write_data=state==CLEAR?32'd0:{interpolation_rgb,8'd0};
    // 每行一个同步读口；左右邻点分两拍读，避免RAM复制。
    always @(posedge clk)begin
        if(pixel_valid && pixel_ready && coordinates_match && state==RECEIVE)begin
            if(source_row[0])odd_line[pixel_x[LINE_BITS-1:0]]<=pixel_rgb;
            else even_line[pixel_x[LINE_BITS-1:0]]<=pixel_rgb;
        end
        if(state==FETCH_LEFT || state==CAPTURE_LEFT)begin
            even_pixel<=even_line[memory_x];
            odd_pixel<=odd_line[memory_x];
        end
    end
    task fail(input [3:0] code);
        begin state<=FAILED;done<=0;error<=1;error_code<=code;end
    endtask
    always @(posedge clk or posedge rst)begin
        if(rst)begin
            state<=IDLE;sw<=0;sh<=0;last_source_x<=0;last_source_y<=0;fit_w<=0;fit_h<=0;off_x<=0;off_y<=0;
            source_row<=0;input_x<=0;target_x<=0;target_y<=0;map_y0<=0;map_y1<=0;
            reverse_rows<=0;have_row<=0;width_limited<=0;geometry_phase<=0;
            width_product<=0;height_product<=0;x_fixed<=0;x_step<=0;x_error<=0;x_step_remainder<=0;
            fraction_y<=0;clear_address<=0;generic_row_address<=0;p00<=0;p01<=0;
            left_address<=0;right_address<=0;
            div_start<=0;numerator<=0;denominator<=1;done<=0;error<=0;error_code<=0;
        end else if(abort)begin
            state<=IDLE;have_row<=0;div_start<=0;done<=0;error<=0;error_code<=0;
        end else begin
            div_start<=0;
            if(start && !busy)begin
                sw<=source_width;sh<=source_height;reverse_rows<=bottom_up;
                last_source_x<=source_width-1'b1;last_source_y<=source_height-1'b1;
                source_row<=bottom_up?source_height-1'b1:0;input_x<=0;have_row<=0;
                done<=0;error<=0;error_code<=0;geometry_phase<=0;
                width_product<=source_width[SOURCE_X_BITS-1:0]*OUTPUT_HEIGHT;
                height_product<=source_height[SOURCE_Y_BITS-1:0]*OUTPUT_WIDTH;
                if(source_width==0 || source_width>MAX_SOURCE_WIDTH || source_height==0 ||
                    source_height>MAX_SOURCE_HEIGHT || MAX_SOURCE_WIDTH<1 || MAX_SOURCE_WIDTH>65535 ||
                    MAX_SOURCE_HEIGHT<1 || MAX_SOURCE_HEIGHT>65535 || OUTPUT_WIDTH<1 || OUTPUT_WIDTH>65535 ||
                    OUTPUT_HEIGHT<1 || OUTPUT_HEIGHT>65535 || FRAME_WORDS>2097152)fail(1);
                else state<=GEOMETRY;
            end else case(state)
                GEOMETRY:begin
                    width_limited<=width_product>=height_product;
                    numerator<=width_product>=height_product?height_product:width_product;
                    denominator<=width_product>=height_product?sw:sh;
                    geometry_phase<=0;div_start<=1;state<=GEOMETRY_WAIT;
                end
                GEOMETRY_WAIT:if(div_done)begin
                    if(div_error)fail(1);
                    else if(!geometry_phase)begin
                        fit_w<=width_limited?OUTPUT_WIDTH:(quotient==0?1:quotient);
                        fit_h<=width_limited?(quotient==0?1:quotient):OUTPUT_HEIGHT;
                        off_x<=width_limited?0:(OUTPUT_WIDTH-(quotient==0?1:quotient))/2;
                        off_y<=width_limited?(OUTPUT_HEIGHT-(quotient==0?1:quotient))/2:0;
                        numerator<={8'd0,sw,8'd0};
                        denominator<=width_limited?OUTPUT_WIDTH:(quotient==0?1:quotient);
                        geometry_phase<=1;div_start<=1;
                    end else begin
                        x_step<=quotient[X_FIXED_BITS-1:0];x_step_remainder<=remainder[15:0];
                        clear_address<=0;target_y<=reverse_rows?fit_h-1'b1:0;state<=CLEAR;
                    end
                end
                CLEAR:if(write_ready)begin
                    // 1280路径借清黑前两次握手准备首行基址，末次握手再复用游标。
                    if(OUTPUT_WIDTH==1280)begin
                        if(clear_address==0)numerator<=first_row_sum;
                        else if(clear_address==1)numerator<={11'd0,first_row_address};
                    end
                    if(clear_address==FRAME_WORDS-1)begin
                        if(OUTPUT_WIDTH==1280)clear_address<=numerator[20:0];
                        state<=Y_BEGIN;
                    end else clear_address<=stepped_cursor;
                end
                Y_BEGIN:begin
                    numerator<=target_y*sh;denominator<=fit_h;div_start<=1;state<=Y_INTEGER_WAIT;
                    if(OUTPUT_WIDTH!=1280)generic_row_address<=(off_y+target_y)*OUTPUT_WIDTH+off_x;
                end
                Y_INTEGER_WAIT:if(div_done)begin
                    if(div_error)fail(1);
                    else begin
                        map_y0<=quotient[15:0];map_y1<=quotient>=last_source_y?last_source_y:quotient[15:0]+1'b1;
                        numerator<={remainder[23:0],8'd0};denominator<=fit_h;div_start<=1;
                        state<=Y_FRACTION_WAIT;
                    end
                end
                Y_FRACTION_WAIT:if(div_done)begin
                    if(div_error)fail(1);
                    else begin
                        fraction_y<=quotient[7:0];target_x<=0;x_fixed<=0;x_error<=0;state<=PAIR_READY;
                    end
                end
                PAIR_READY:if(have_row && latest_y==needed_latest)state<=PREPARE_X;
                           else if(have_row)state<=ADVANCE_SOURCE;
                           else state<=RECEIVE;
                RECEIVE:if(pixel_valid)begin
                    if(!coordinates_match)fail(2);
                    else if(input_x==last_source_x)begin
                        input_x<=0;have_row<=1;state<=PAIR_READY;
                    end else input_x<=input_x+1'b1;
                end else if(source_done)fail(3);
                ADVANCE_SOURCE:if(source_last)fail(4);
                               else begin
                                   source_row<=reverse_rows?source_row-1'b1:source_row+1'b1;
                                   have_row<=0;state<=RECEIVE;
                               end
                PREPARE_X:begin
                    left_address<=left_x[LINE_BITS-1:0];right_address<=right_x[LINE_BITS-1:0];state<=FETCH_LEFT;
                end
                FETCH_LEFT:state<=CAPTURE_LEFT;
                CAPTURE_LEFT:begin
                    p00<=map_y0[0]?odd_pixel:even_pixel;
                    p01<=map_y1[0]?odd_pixel:even_pixel;state<=CAPTURE_RIGHT;
                end
                CAPTURE_RIGHT:state<=INTERPOLATE;
                INTERPOLATE:if(interpolation_ready)state<=SEND;
                SEND:if(interpolation_valid && write_ready)begin
                    if(target_x==fit_w-1'b1)state<=NEXT_ROW;
                    else begin
                        target_x<=target_x+1'b1;x_fixed<=x_fixed+x_step+x_carry;
                        x_error<=x_carry?next_error-fit_w:next_error;
                        state<=PREPARE_X;
                    end
                end
                NEXT_ROW:if(target_last)begin
                    if(source_last)begin state<=FINISHED;done<=1;end
                    else begin
                        source_row<=reverse_rows?source_row-1'b1:source_row+1'b1;
                        have_row<=0;state<=DRAIN;
                    end
                end else begin
                    target_y<=reverse_rows?target_y-1'b1:target_y+1'b1;
                    if(OUTPUT_WIDTH==1280)clear_address<=stepped_cursor;
                    state<=Y_BEGIN;
                end
                DRAIN:if(pixel_valid)begin
                    if(!coordinates_match)fail(2);
                    else if(input_x==last_source_x)begin
                        input_x<=0;
                        if(source_last)begin state<=FINISHED;done<=1;end
                        else source_row<=reverse_rows?source_row-1'b1:source_row+1'b1;
                    end else input_x<=input_x+1'b1;
                end else if(source_done)fail(3);
                IDLE,FINISHED,FAILED:begin end
                default:fail(4);
            endcase
        end
    end
endmodule
