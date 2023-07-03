`timescale 1ns / 1ps
module merge_sort #(
    parameter DATA_WIDTH=8,
    parameter BPS_L=1,
    parameter BPN_L=128,
    parameter READ_PIXEL=16,
    parameter BPS_R=BPS_L+BPN_L+READ_PIXEL,
    parameter BPN_R=128
    ) (
    input clk_p,
    input clk_n,
    input rst_n,
    input i_valid,
    input i_ready,
    input [DATA_WIDTH-1:0] idata,
    output reg o_valid,
    output o_ready,
    output reg [DATA_WIDTH-1:0] odata
    );
    
    wire clk;
    IBUFDS RXD_FPGA_diff (
        .I(clk_p),
        .IB(clk_n),
        .O(clk)
    );
    
    reg [15:0] pixel_cnt_r;//指示当前输入的像素的位置
    reg [READ_PIXEL*DATA_WIDTH-1:0] line_buffer_r;//存储有效像素
    reg [11:0] ready_delay_r;//将ready信号打一拍用于将ready整形成上升沿信号
    
    reg [2*DATA_WIDTH-1:0] level_1_r;//第一级比较
    reg [2*DATA_WIDTH-1:0] level_1_c_r;//第一级比较
    reg level_1_valid_d;
    reg level_1_valid_t;
    wire level_1_valid;
    reg level_1_valid_r;
    
    reg [4*DATA_WIDTH-1:0] level_2_r;//第二级比较
    wire [4*DATA_WIDTH-1:0] level_2_c_r;//第二级比较
    reg level_2_valid_d;
    reg level_2_valid_t;
    wire level_2_valid;
    wire level_2_valid_r;
    
    reg [8*DATA_WIDTH-1:0] level_3_r;//第三级比较
    wire [8*DATA_WIDTH-1:0] level_3_c_r;//第三级比较
    reg level_3_valid_d;
    reg level_3_valid_t;
    wire level_3_valid;
    wire level_3_valid_r;
    
    reg [16*DATA_WIDTH-1:0] level_4_r;//第四级比较
    wire [16*DATA_WIDTH-1:0] level_4_c_r;//第四级比较
    reg level_4_valid_d;
    reg level_4_valid_t;
    wire level_4_valid;
    wire level_4_valid_r;
    
    reg [32*DATA_WIDTH-1:0] level_5_r;//第五级比较
    wire [32*DATA_WIDTH-1:0] level_5_c_r;//第五级比较
    reg level_5_valid_d;
    reg level_5_valid_t;
    wire level_5_valid;
    wire level_5_valid_r;
    
    reg [64*DATA_WIDTH-1:0] level_6_r;//第六级比较
    wire [64*DATA_WIDTH-1:0] level_6_c_r;//第六级比较
    reg level_6_valid_d;
    reg level_6_valid_t;
    wire level_6_valid;
    wire level_6_valid_r;
    
    reg [128*DATA_WIDTH-1:0] level_7_r;//第七级比较
    wire [128*DATA_WIDTH-1:0] level_7_c_r;//第七级比较
    reg level_7_valid_d;
    reg level_7_valid_t;
    wire level_7_valid;
    wire level_7_valid_r;
    
    reg [256*DATA_WIDTH-1:0] level_8_r;//第八级比较
    wire [DATA_WIDTH-1:0] level_8_c_r;//第八级比较
    reg level_8_valid_d;
    reg level_8_valid_t;
    wire level_8_valid;
    wire level_8_valid_r;
    
    reg [DATA_WIDTH-1:0] ref_data;
    reg ref_valid;
    
    //指示输入的像素为暗像素还是有效像素
    wire active_pixel_exist;
    wire black_pixel_exist;
    
    //反压信号
    wire ready;
    wire ready_i;
    reg frame_ready;
    wire o_ready_t;
    
    //产生行间复位信号
    wire reset_signal;
    reg o_ready_delay_r;
    reg [4:0] read_pixel_cnt;
    
    //------------------------------Combination Logic------------------------------//
    //指示输入的像素为暗像素还是有效像素
    assign active_pixel_exist = (pixel_cnt_r >=BPS_L+BPN_L) && (pixel_cnt_r<BPS_R);
    assign black_pixel_exist = ((pixel_cnt_r>=BPS_L) && (pixel_cnt_r<BPS_L+BPN_L)) || ((pixel_cnt_r>=BPS_R) && (pixel_cnt_r<BPS_R+BPN_R));
    
    //反压信号
    assign ready=i_ready&(!o_ready_t);
    assign ready_i = ready_delay_r[10]&(!ready_delay_r[11]);
    
    //产生行间复位信号
    assign reset_signal = o_ready_t & (!o_ready_delay_r);
    
    //产生ready信号
     assign o_ready_t = read_pixel_cnt == 0;
     assign o_ready = o_ready_t & frame_ready;
    
    //------------------------------Timing Logic------------------------------//
    //整形ready信号
    always@(posedge clk or negedge rst_n)begin
        if(!rst_n)
            ready_delay_r <= 'd0;
        else
            ready_delay_r <= {ready_delay_r[10:0],ready};
    end
    
    //指示当前输入的像素的位置
    always@(posedge clk or negedge rst_n)begin
        if(!rst_n)
            pixel_cnt_r <= 'd0;
        else if(pixel_cnt_r == 1 + BPN_L + READ_PIXEL + BPN_R && i_valid)
            pixel_cnt_r <= 'd0;
        else if(i_valid)
            pixel_cnt_r <= pixel_cnt_r + 1;
    end
    
    //缓存有效像素
    always@(posedge clk  or negedge rst_n)begin
        if(!rst_n)
            line_buffer_r <= 'd0;
        else if(i_valid && active_pixel_exist)
            line_buffer_r <= {line_buffer_r[(READ_PIXEL-1)*DATA_WIDTH-1:0],idata};
        else if(ready_i&&(!o_ready_t))
            line_buffer_r <= line_buffer_r<<DATA_WIDTH;
    end
    
    //第一级比较
    always@(posedge clk or negedge rst_n)begin
        if(!rst_n)begin
            level_1_r <= 'd0;
            level_1_valid_t <= 'b0;
        end
        else if(i_valid && black_pixel_exist)begin
            level_1_r <= {level_1_r[0+:DATA_WIDTH],idata};
            level_1_valid_t <= ~level_1_valid_t;
        end
    end
    
    always@(posedge clk or negedge rst_n)begin
        if(!rst_n)begin
            level_1_valid_d <= 'd0;
            level_1_valid_r <= 'd0;
        end
        else begin
            level_1_valid_d <= level_1_valid_t;
            level_1_valid_r <= level_1_valid;
        end
    end
        
    assign level_1_valid=level_1_valid_d&(~level_1_valid_t);
    
    always@(posedge clk or negedge rst_n)begin
        if(!rst_n)
            level_1_c_r <='d0;
        else if(level_1_valid)
            if(level_1_r[0+:DATA_WIDTH]>level_1_r[DATA_WIDTH+:DATA_WIDTH])
                level_1_c_r <= {level_1_r[0+:DATA_WIDTH],level_1_r[DATA_WIDTH+:DATA_WIDTH]};
            else
                level_1_c_r <= level_1_r;
    end
    
    //第二级比较
    always@(posedge clk or negedge rst_n)begin
        if(!rst_n)begin
            level_2_r <= 'd0;
            level_2_valid_t <= 'b0;
        end
        else if(level_1_valid_r)begin
            level_2_r <= {level_2_r[0+:2*DATA_WIDTH],level_1_c_r};
            level_2_valid_t <= ~level_2_valid_t;
        end
    end    
    
    always@(posedge clk or negedge rst_n)begin
        if(!rst_n)
            level_2_valid_d <= 'd0;
        else
            level_2_valid_d <= level_2_valid_t;
    end
    
    assign level_2_valid=level_2_valid_d&(~level_2_valid_t);
    
    level_2_gen #(
        .DATA_WIDTH(DATA_WIDTH)
    ) u_level_2_gen (
        .clk(clk),
        .rst_n(rst_n),
        .idata(level_2_r),
        .ivalid(level_2_valid),
        .odata(level_2_c_r),
        .ovalid(level_2_valid_r)
    );
    
    //第三级比较
    always@(posedge clk or negedge rst_n)begin
        if(!rst_n)begin
            level_3_r <= 'd0;
            level_3_valid_t <= 'b0;
        end
        else if(level_2_valid_r)begin
            level_3_r <= {level_3_r[0+:4*DATA_WIDTH],level_2_c_r};
            level_3_valid_t <= ~level_3_valid_t;
        end
    end   
    
    always@(posedge clk or negedge rst_n)begin
        if(!rst_n)
            level_3_valid_d <= 'd0;
        else
            level_3_valid_d <= level_3_valid_t;
    end
    
    assign level_3_valid=level_3_valid_d&(~level_3_valid_t);
    
    level_3_gen #(
        .DATA_WIDTH(DATA_WIDTH)
    ) u_level_3_gen (
        .clk(clk),
        .rst_n(rst_n),
        .idata(level_3_r),
        .ivalid(level_3_valid),
        .odata(level_3_c_r),
        .ovalid(level_3_valid_r)
    );
    
    //第四级比较
    always@(posedge clk or negedge rst_n)begin
        if(!rst_n)begin
            level_4_r <= 'd0;
            level_4_valid_t <= 'b0;
        end
        else if(level_3_valid_r)begin
            level_4_r <= {level_4_r[0+:8*DATA_WIDTH],level_3_c_r};
            level_4_valid_t <= ~level_4_valid_t;
        end
    end   
    
    always@(posedge clk or negedge rst_n)begin
        if(!rst_n)
            level_4_valid_d <= 'd0;
        else
            level_4_valid_d <= level_4_valid_t;
    end
    
    assign level_4_valid=level_4_valid_d&(~level_4_valid_t);
    
    level_4_gen #(
        .DATA_WIDTH(DATA_WIDTH)
    ) u_level_4_gen (
        .clk(clk),
        .rst_n(rst_n),
        .idata(level_4_r),
        .ivalid(level_4_valid),
        .odata(level_4_c_r),
        .ovalid(level_4_valid_r)
    );
    
    //第五级比较
    always@(posedge clk or negedge rst_n)begin
        if(!rst_n)begin
            level_5_r <= 'd0;
            level_5_valid_t <= 'b0;
        end
        else if(level_4_valid_r)begin
            level_5_r <= {level_5_r[0+:16*DATA_WIDTH],level_4_c_r};
            level_5_valid_t <= ~level_5_valid_t;
        end
    end   
    
    always@(posedge clk or negedge rst_n)begin
        if(!rst_n)
            level_5_valid_d <= 'd0;
        else
            level_5_valid_d <= level_5_valid_t;
    end
    
    assign level_5_valid=level_5_valid_d&(~level_5_valid_t);
    
    level_5_gen #(
        .DATA_WIDTH(DATA_WIDTH)
    ) u_level_5_gen (
        .clk(clk),
        .rst_n(rst_n),
        .idata(level_5_r),
        .ivalid(level_5_valid),
        .odata(level_5_c_r),
        .ovalid(level_5_valid_r)
    );
    
    //第六级比较
    always@(posedge clk or negedge rst_n)begin
        if(!rst_n)begin
            level_6_r <= 'd0;
            level_6_valid_t <= 'b0;
        end
        else if(level_5_valid_r)begin
            level_6_r <= {level_6_r[0+:32*DATA_WIDTH],level_5_c_r};
            level_6_valid_t <= ~level_6_valid_t;
        end
    end   
    
    always@(posedge clk or negedge rst_n)begin
        if(!rst_n)
            level_6_valid_d <= 'd0;
        else
            level_6_valid_d <= level_6_valid_t;
    end
    
    assign level_6_valid=level_6_valid_d&(~level_6_valid_t);
    
    level_6_gen #(
        .DATA_WIDTH(DATA_WIDTH)
    ) u_level_6_gen (
        .clk(clk),
        .rst_n(rst_n),
        .idata(level_6_r),
        .ivalid(level_6_valid),
        .odata(level_6_c_r),
        .ovalid(level_6_valid_r)
    );
    
    //第七级比较
    always@(posedge clk or negedge rst_n)begin
        if(!rst_n)begin
            level_7_r <= 'd0;
            level_7_valid_t <= 'b0;
        end
        else if(level_6_valid_r)begin
            level_7_r <= {level_7_r[0+:64*DATA_WIDTH],level_6_c_r};
            level_7_valid_t <= ~level_7_valid_t;
        end
    end   
    
    always@(posedge clk or negedge rst_n)begin
        if(!rst_n)
            level_7_valid_d <= 'd0;
        else
            level_7_valid_d <= level_7_valid_t;
    end
    
    assign level_7_valid=level_7_valid_d&(~level_7_valid_t);
    
    level_7_gen #(
        .DATA_WIDTH(DATA_WIDTH)
    ) u_level_7_gen (
        .clk(clk),
        .rst_n(rst_n),
        .idata(level_7_r),
        .ivalid(level_7_valid),
        .odata(level_7_c_r),
        .ovalid(level_7_valid_r)
    );
    
    //第八级比较
    always@(posedge clk or negedge rst_n)begin
        if(!rst_n)begin
            level_8_r <= 'd0;
            level_8_valid_t <= 'b0;
        end
        else if(level_7_valid_r)begin
            level_8_r <= {level_8_r[0+:128*DATA_WIDTH],level_7_c_r};
            level_8_valid_t <= ~level_8_valid_t;
        end
    end   
    
    always@(posedge clk or negedge rst_n)begin
        if(!rst_n)
            level_8_valid_d <= 'd0;
        else
            level_8_valid_d <= level_8_valid_t;
    end
    
    assign level_8_valid=level_8_valid_d&(~level_8_valid_t);
    
    level_8_gen #(
        .DATA_WIDTH(DATA_WIDTH)
    ) u_level_8_gen (
        .clk(clk),
        .rst_n(rst_n),
        .idata(level_8_r),
        .ivalid(level_8_valid),
        .odata(level_8_c_r),
        .ovalid(level_8_valid_r)
    );
    
    always@(posedge clk or negedge rst_n)begin
        if(!rst_n)
            ref_data <='d0;
        else if(level_8_valid_r)
            ref_data <= level_8_c_r;
    end
    
    always@(posedge clk or negedge rst_n)begin
        if(!rst_n)
            ref_valid <='d0;
        else
            ref_valid <= level_8_valid_r;
    end

    //产生行间复位信号
    always@(posedge clk or negedge rst_n)begin
        if(!rst_n)
            o_ready_delay_r <= 1'b0;
        else
            o_ready_delay_r <= o_ready_t;
    end
    
    //产生o_ready信号
    always@(posedge clk or negedge rst_n)begin
        if(!rst_n)
            read_pixel_cnt <= 'd0;
        else if(read_pixel_cnt == READ_PIXEL+1)
            read_pixel_cnt <= 1'b0;
        else if(read_pixel_cnt > 0 && ready_i)
            read_pixel_cnt <= read_pixel_cnt + 1;
        else if(ref_valid)
            read_pixel_cnt <= 1'b1;
    end
    
    //产生校正后像素值与o_valid信号
    always@(posedge clk or negedge rst_n)begin
        if(!rst_n)begin
            odata <= 'd0;
            o_valid <= 1'b0;
        end
        else if(ready_i&&(!o_ready_t))begin
            odata <= line_buffer_r[READ_PIXEL*DATA_WIDTH-1:(READ_PIXEL-1)*DATA_WIDTH] - ref_data;
            o_valid <= 1'b1;
        end
        else
            o_valid <= 1'b0;
    end     
    
    always@(posedge clk or negedge rst_n)begin
        if(!rst_n)
            frame_ready <= 'b1;
        else if(pixel_cnt_r==1 + BPN_L + READ_PIXEL + BPN_R)
            frame_ready <= 'b0;
        else if(!o_ready_t)
            frame_ready <= 'b1;
    end
endmodule
