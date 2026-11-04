`timescale 1ns/1ps
// 加载端单行RAM最近邻比例缩放。黑边先清零，再写居中图像；输出word地址不含bank基址。
module nearest_frame_scaler #(
    parameter integer OUTPUT_WIDTH=1280,OUTPUT_HEIGHT=720,MAX_SOURCE_WIDTH=1920,MAX_SOURCE_HEIGHT=1080
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
    localparam IDLE=0,GEOM=1,GEOM_WAIT=2,CLEAR=3,Y_CALC=4,Y_WAIT=5,RECEIVE=6,
        ROW_FETCH=7,ROW_SEND=8,NEXT_SOURCE=9,FINISHED=10,FAILED=11;
    reg [3:0] state;
    reg [15:0] sw,sh,fit_w,fit_h,off_x,off_y,source_row,input_x,target_row,target_x,map_x;
    reg reverse_rows,width_limited,have_row,all_rows_done;
    reg [31:0] width_product,height_product,x_remainder;
    reg [20:0] clear_address,row_address;
    wire [16:0] row_sum={1'b0,off_y}+{1'b0,target_row};
    wire [31:0] row_product={15'd0,x_remainder[16:0]}*OUTPUT_WIDTH;
    wire [31:0] row_base_address;
    wire [31:0] x_advance=x_remainder+{16'd0,x_residue};
    wire x_carry=x_advance>={16'd0,fit_w};
    wire [31:0] next_x_remainder=x_carry?x_advance-{16'd0,fit_w}:x_advance;
    generate if(OUTPUT_WIDTH==1280)begin:prepared_row_base
        assign row_base_address=x_remainder+{16'd0,off_x};
    end else begin:generic_row_base
        assign row_base_address=(off_y+target_row)*OUTPUT_WIDTH+off_x;
    end endgenerate
    localparam LINE_BITS=(MAX_SOURCE_WIDTH<2)?1:$clog2(MAX_SOURCE_WIDTH);
    (* ram_style="bram" *) reg [23:0] line[0:(1<<LINE_BITS)-1];
    reg [23:0] line_pixel;
    reg div_start;
    reg [31:0] numerator,denominator;
    wire div_busy,div_done,div_error;
    wire [31:0] quotient,remainder;
    // 水平比率最大1920:1，预先商余数后每像素只加减一次。
    reg [15:0] x_quotient,x_residue;
    reg [2:0] geom_phase;
    unsigned_divider divide(.clk(clk),.rst(rst),.abort(abort),.start(div_start),
        .dividend(numerator),.divisor(denominator),.busy(div_busy),.done(div_done),.error(div_error),
        .quotient(quotient),.remainder(remainder));
    assign busy=state!=IDLE && state!=FINISHED && state!=FAILED;
    assign pixel_ready=state==RECEIVE && !abort;
    assign write_valid=(state==CLEAR || state==ROW_SEND) && !abort;
    assign write_address=state==CLEAR?clear_address:row_address+target_x;
    assign write_data=state==CLEAR?0:{line_pixel,8'd0};
    always @(posedge clk)begin
        if(pixel_valid && pixel_ready && pixel_x<MAX_SOURCE_WIDTH)line[pixel_x[LINE_BITS-1:0]]<=pixel_rgb;
        if(state==ROW_FETCH)line_pixel<=line[map_x[LINE_BITS-1:0]];
    end
    task fail(input [3:0] code);
        begin state<=FAILED;error<=1;error_code<=code;end
    endtask
    always @(posedge clk or posedge rst)begin
        if(rst)begin
            state<=IDLE;sw<=0;sh<=0;fit_w<=0;fit_h<=0;off_x<=0;off_y<=0;source_row<=0;
            input_x<=0;target_row<=0;target_x<=0;map_x<=0;reverse_rows<=0;
            width_limited<=0;have_row<=0;all_rows_done<=0;clear_address<=0;row_address<=0;
            width_product<=0;height_product<=0;x_remainder<=0;
            x_quotient<=0;x_residue<=0;geom_phase<=0;div_start<=0;numerator<=0;denominator<=1;
            done<=0;error<=0;error_code<=0;
        end else if(abort)begin state<=IDLE;done<=0;error<=0;error_code<=0;div_start<=0;end
        else begin
            div_start<=0;
            if(start && !busy)begin
                done<=0;error<=0;error_code<=0;sw<=source_width;sh<=source_height;reverse_rows<=bottom_up;
                width_product<=source_width*OUTPUT_HEIGHT;height_product<=source_height*OUTPUT_WIDTH;
                input_x<=0;source_row<=bottom_up?source_height-1'b1:0;have_row<=0;all_rows_done<=0;
                if(source_width==0 || source_width>MAX_SOURCE_WIDTH || source_height==0 || source_height>MAX_SOURCE_HEIGHT)fail(1);
                else state<=GEOM;
            end else case(state)
                GEOM:begin
                    width_limited<=width_product>=height_product;geom_phase<=0;
                    numerator<=width_product>=height_product?height_product:width_product;
                    denominator<=width_product>=height_product?sw:sh;div_start<=1;state<=GEOM_WAIT;
                end
                GEOM_WAIT:if(div_done)begin
                    if(geom_phase==0)begin
                        fit_w<=width_limited?OUTPUT_WIDTH:(quotient==0?1:quotient);
                        fit_h<=width_limited?(quotient==0?1:quotient):OUTPUT_HEIGHT;
                        off_x<=width_limited?0:(OUTPUT_WIDTH-(quotient==0?1:quotient))/2;
                        off_y<=width_limited?(OUTPUT_HEIGHT-(quotient==0?1:quotient))/2:0;
                        numerator<=sw;denominator<=width_limited?OUTPUT_WIDTH:(quotient==0?1:quotient);
                        div_start<=1;geom_phase<=1;
                    end else begin
                        x_quotient<=quotient[15:0];x_residue<=remainder[15:0];
                        clear_address<=0;target_row<=reverse_rows?fit_h-1'b1:0;state<=CLEAR;
                    end
                end
                CLEAR:if(write_ready)begin
                    if(clear_address==OUTPUT_WIDTH*OUTPUT_HEIGHT-1)state<=Y_CALC;
                    else clear_address<=clear_address+1'b1;
                end
                Y_CALC:begin
                    numerator<=target_row*sh;denominator<=fit_h;div_start<=1;state<=Y_WAIT;
                    if(OUTPUT_WIDTH==1280)x_remainder<={15'd0,row_sum};
                end
                // DIV首启动沿完成基址，等待/跳源行期间保存；消费沿清0后恢复横DDA。
                Y_WAIT:if(OUTPUT_WIDTH==1280 && div_start)begin
                    x_remainder<={11'd0,row_product[20:0]};
                end else if(div_done)begin
                    // source_row为规范化y；倒序输入只影响到达顺序，不再次翻转像素坐标。
                    if(have_row && quotient==source_row)begin
                        row_address<=row_base_address[20:0];
                        target_x<=0;map_x<=0;x_remainder<=0;state<=ROW_FETCH;
                    end else if(have_row)state<=NEXT_SOURCE;
                    else state<=RECEIVE;
                end
                RECEIVE:begin
                    if(pixel_valid)begin
                        if(pixel_x!=input_x || pixel_y!=source_row)fail(2);
                        else if(input_x==sw-1'b1)begin
                            input_x<=0;have_row<=1;
                            if(!all_rows_done && quotient==source_row)begin
                                row_address<=row_base_address[20:0];
                                target_x<=0;map_x<=0;x_remainder<=0;state<=ROW_FETCH;
                            end else state<=NEXT_SOURCE;
                        end else input_x<=input_x+1'b1;
                    end else if(source_done)fail(3);
                end
                ROW_FETCH:state<=ROW_SEND;
                ROW_SEND:if(write_ready)begin
                    // 行尾余数不再消费；下一行Y_CALC覆盖，使共享寄存器CE不经过last比较。
                    if(OUTPUT_WIDTH==1280)x_remainder<=next_x_remainder;
                    if(target_x==fit_w-1'b1)begin
                        if((!reverse_rows && target_row==fit_h-1'b1) || (reverse_rows && target_row==0))begin
                            all_rows_done<=1;state<=NEXT_SOURCE;
                        end else begin target_row<=reverse_rows?target_row-1'b1:target_row+1'b1;state<=Y_CALC;end
                    end else begin
                        target_x<=target_x+1'b1;
                        if(OUTPUT_WIDTH!=1280)x_remainder<=next_x_remainder;
                        if(x_carry)map_x<=map_x+x_quotient+1'b1;
                        else map_x<=map_x+x_quotient;
                        state<=ROW_FETCH;
                    end
                end
                NEXT_SOURCE:begin
                    have_row<=0;
                    if((!reverse_rows && source_row==sh-1'b1) || (reverse_rows && source_row==0))begin
                        if(all_rows_done)begin state<=FINISHED;done<=1;end else fail(4);
                    end else begin source_row<=reverse_rows?source_row-1'b1:source_row+1'b1;state<=RECEIVE;end
                end
            endcase
        end
    end
endmodule
