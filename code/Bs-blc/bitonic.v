`timescale 1ns / 1ps
module bitonic #(
    parameter DATA_WIDTH=8,
    parameter BPS_L=1,
    parameter BPN_L=128,
    parameter READ_PIXEL=16,
    parameter BPS_R=BPS_L+BPN_L+READ_PIXEL,
    parameter BPN_R=128
)(
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
    
    reg ascend;
    always@(posedge clk or negedge rst_n)begin
        if(!rst_n)
            ascend <= 0;
         else if (level_1_valid)
            ascend <= ~ascend;
    end
    
    //构建第一级双调
    always@(posedge clk or negedge rst_n)begin
        if(!rst_n)
            level_1_c_r <='d0;
        else if(level_1_valid)
            if(level_1_r[0+:DATA_WIDTH]>level_1_r[DATA_WIDTH+:DATA_WIDTH] && ascend)
                level_1_c_r <= {level_1_r[0+:DATA_WIDTH],level_1_r[DATA_WIDTH+:DATA_WIDTH]};
            else if(level_1_r[0+:DATA_WIDTH]<level_1_r[DATA_WIDTH+:DATA_WIDTH] && !ascend)
                level_1_c_r <= {level_1_r[0+:DATA_WIDTH],level_1_r[DATA_WIDTH+:DATA_WIDTH]};
            else
                level_1_c_r <= level_1_r;
    end
    
    //构建第二级双调
    reg [4*DATA_WIDTH-1:0] level_2_r;
    reg [4*DATA_WIDTH-1:0] level_2_c_r;
    reg [1:0] level_2_c_valid;
    wire [4*DATA_WIDTH-1:0] level_2_w;
    wire [2*DATA_WIDTH-1:0] level_2_max_t;
    wire [2*DATA_WIDTH-1:0] level_2_min_t;
    wire [2*DATA_WIDTH-1:0] level_2_max;
    wire [2*DATA_WIDTH-1:0] level_2_min;
    assign level_2_max_t[0+:DATA_WIDTH] = (level_2_r[31-:DATA_WIDTH]>level_2_r[15-:DATA_WIDTH]) ? level_2_r[31-:DATA_WIDTH] : level_2_r[15-:DATA_WIDTH]; 
    assign level_2_max_t[DATA_WIDTH+:DATA_WIDTH] = (level_2_r[23-:DATA_WIDTH]>level_2_r[7-:DATA_WIDTH]) ? level_2_r[23-:DATA_WIDTH] : level_2_r[7-:DATA_WIDTH]; 
    assign level_2_min_t[0+:DATA_WIDTH] = (level_2_r[31-:DATA_WIDTH]>level_2_r[15-:DATA_WIDTH]) ? level_2_r[15-:DATA_WIDTH] : level_2_r[31-:DATA_WIDTH]; 
    assign level_2_min_t[DATA_WIDTH+:DATA_WIDTH] = (level_2_r[23-:DATA_WIDTH]>level_2_r[7-:DATA_WIDTH]) ? level_2_r[7-:DATA_WIDTH] : level_2_r[23-:DATA_WIDTH]; 
    assign level_2_max = (level_2_max_t[0+:DATA_WIDTH] > level_2_max_t[DATA_WIDTH+:DATA_WIDTH]) ? level_2_max_t : {level_2_max_t[0+:DATA_WIDTH],level_2_max_t[DATA_WIDTH+:DATA_WIDTH]};
    assign level_2_min = (level_2_min_t[0+:DATA_WIDTH] > level_2_min_t[DATA_WIDTH+:DATA_WIDTH]) ? level_2_min_t : {level_2_min_t[0+:DATA_WIDTH],level_2_min_t[DATA_WIDTH+:DATA_WIDTH]};
    assign level_2_w = {level_2_min,level_2_max};
    always @(posedge clk or negedge rst_n)begin
        if(!rst_n)
            level_2_r <= 'd0;
        else if(level_1_valid_r)
            level_2_r <= {level_2_r[0+:2*DATA_WIDTH],level_1_c_r};
        else
            level_2_r <= level_2_r;
    end
    
    always @(posedge clk or negedge rst_n)begin
        if(!rst_n)
        begin
            level_2_c_r <= 'd0;
            level_2_c_valid <= 1'b0;
        end
        else
        begin
            level_2_c_valid <= {level_2_c_valid[0],level_1_valid_r & !ascend};
            level_2_c_r <= level_2_w;
        end
    end
    
    
    //构建第3级双调
    reg [8*DATA_WIDTH-1:0] level_3_r;
    reg [8*DATA_WIDTH-1:0] level_3_c_r;
    reg ascend_3;
    reg [1:0] level_3_c_valid;
    wire [4*DATA_WIDTH-1:0] level_3_1_max;
    wire [4*DATA_WIDTH-1:0] level_3_1_min;
    wire [2*DATA_WIDTH-1:0] level_3_2_max_max_t;
    wire [2*DATA_WIDTH-1:0] level_3_2_max_min_t;
    wire [2*DATA_WIDTH-1:0] level_3_2_min_max_t;
    wire [2*DATA_WIDTH-1:0] level_3_2_min_min_t;
    wire [2*DATA_WIDTH-1:0] level_3_2_max_max;
    wire [2*DATA_WIDTH-1:0] level_3_2_max_min;
    wire [2*DATA_WIDTH-1:0] level_3_2_min_max;
    wire [2*DATA_WIDTH-1:0] level_3_2_min_min;    
    wire [8*DATA_WIDTH-1:0] level_3_w;
    
    genvar i;
    generate
    for (i=0;i<4;i=i+1)
        begin:gen_3_1
            assign level_3_1_max[i*DATA_WIDTH+:DATA_WIDTH] = (level_3_r[(8-i)*DATA_WIDTH-1-:DATA_WIDTH] >level_3_r[i*DATA_WIDTH+:DATA_WIDTH]) ? level_3_r[(8-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_3_r[i*DATA_WIDTH+:DATA_WIDTH];   
            assign level_3_1_min[i*DATA_WIDTH+:DATA_WIDTH] = (level_3_r[(8-i)*DATA_WIDTH-1-:DATA_WIDTH] >level_3_r[i*DATA_WIDTH+:DATA_WIDTH]) ?  level_3_r[i*DATA_WIDTH+:DATA_WIDTH] : level_3_r[(8-i)*DATA_WIDTH-1-:DATA_WIDTH];
        end
    endgenerate
    
    generate
    for (i=0;i<2;i=i+1)
        begin:gen_3_2
            assign level_3_2_max_max_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_3_1_max[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_3_1_max[(2-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_3_1_max[(4-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_3_1_max[(2-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_3_2_max_min_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_3_1_max[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_3_1_max[(2-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_3_1_max[(2-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_3_1_max[(4-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_3_2_min_max_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_3_1_min[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_3_1_min[(2-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_3_1_min[(4-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_3_1_min[(2-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_3_2_min_min_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_3_1_min[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_3_1_min[(2-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_3_1_min[(2-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_3_1_min[(4-i)*DATA_WIDTH-1-:DATA_WIDTH];           
        end
    endgenerate
    
    assign level_3_2_max_max = (level_3_2_max_max_t[0+:DATA_WIDTH]>level_3_2_max_max_t[DATA_WIDTH+:DATA_WIDTH]) ? level_3_2_max_max_t : {level_3_2_max_max_t[0+:DATA_WIDTH],level_3_2_max_max_t[DATA_WIDTH+:DATA_WIDTH]};
    assign level_3_2_max_min = (level_3_2_max_min_t[0+:DATA_WIDTH]>level_3_2_max_min_t[DATA_WIDTH+:DATA_WIDTH]) ? level_3_2_max_min_t : {level_3_2_max_min_t[0+:DATA_WIDTH],level_3_2_max_min_t[DATA_WIDTH+:DATA_WIDTH]};
    assign level_3_2_min_max = (level_3_2_min_max_t[0+:DATA_WIDTH]>level_3_2_min_max_t[DATA_WIDTH+:DATA_WIDTH]) ? level_3_2_min_max_t : {level_3_2_min_max_t[0+:DATA_WIDTH],level_3_2_min_max_t[DATA_WIDTH+:DATA_WIDTH]};
    assign level_3_2_min_min = (level_3_2_min_min_t[0+:DATA_WIDTH]>level_3_2_min_min_t[DATA_WIDTH+:DATA_WIDTH]) ? level_3_2_min_min_t : {level_3_2_min_min_t[0+:DATA_WIDTH],level_3_2_min_min_t[DATA_WIDTH+:DATA_WIDTH]};
    
    assign level_3_w = {level_3_2_min_min,level_3_2_min_max,level_3_2_max_min,level_3_2_max_max};
    
    always@(posedge clk or negedge rst_n)
    begin
        if (!rst_n)
            level_3_r <= 'd0;
        else if(level_2_c_valid[1])
            level_3_r <= {level_3_r[0+:4*DATA_WIDTH],level_2_c_r};
        else
            level_3_r <= level_3_r;
    end
    
    always@(posedge clk or negedge rst_n)
    begin
        if(!rst_n)
            level_3_c_r <= 'd0;
        else
            level_3_c_r <= level_3_w;
    end
    
    always@(posedge clk or negedge rst_n)
    begin
        if(!rst_n)
            ascend_3 <= 1'b0;
        else if(level_2_c_valid[1])
            ascend_3 <= ~ascend_3;
    end
    
    always@(posedge clk or negedge rst_n)
    begin
        if (!rst_n)
            level_3_c_valid <= 'd0;
        else
            level_3_c_valid <= {level_3_c_valid[0],level_2_c_valid[1]};
    end
    
    //构建第4级双调
    reg [16*DATA_WIDTH-1:0] level_4_r;
    reg [16*DATA_WIDTH-1:0] level_4_c_r;
    reg ascend_4;
    reg [1:0] level_4_c_valid;
    wire [8*DATA_WIDTH-1:0] level_4_1_max;
    wire [8*DATA_WIDTH-1:0] level_4_1_min;
    
    wire [4*DATA_WIDTH-1:0] level_4_2_max_max_t;
    wire [4*DATA_WIDTH-1:0] level_4_2_max_min_t;
    wire [4*DATA_WIDTH-1:0] level_4_2_min_max_t;
    wire [4*DATA_WIDTH-1:0] level_4_2_min_min_t;
    
    wire [2*DATA_WIDTH-1:0] level_4_3_max_max_max_t;
    wire [2*DATA_WIDTH-1:0] level_4_3_max_max_min_t;
    wire [2*DATA_WIDTH-1:0] level_4_3_max_min_max_t;
    wire [2*DATA_WIDTH-1:0] level_4_3_max_min_min_t;
    wire [2*DATA_WIDTH-1:0] level_4_3_min_max_max_t;
    wire [2*DATA_WIDTH-1:0] level_4_3_min_max_min_t;
    wire [2*DATA_WIDTH-1:0] level_4_3_min_min_max_t;
    wire [2*DATA_WIDTH-1:0] level_4_3_min_min_min_t;
    
    wire [2*DATA_WIDTH-1:0] level_4_3_max_max_max;
    wire [2*DATA_WIDTH-1:0] level_4_3_max_max_min;
    wire [2*DATA_WIDTH-1:0] level_4_3_max_min_max;
    wire [2*DATA_WIDTH-1:0] level_4_3_max_min_min;
    wire [2*DATA_WIDTH-1:0] level_4_3_min_max_max;
    wire [2*DATA_WIDTH-1:0] level_4_3_min_max_min;
    wire [2*DATA_WIDTH-1:0] level_4_3_min_min_max;
    wire [2*DATA_WIDTH-1:0] level_4_3_min_min_min;
    wire [16*DATA_WIDTH-1:0] level_4_w;
    
    generate
    for (i=0;i<8;i=i+1)
        begin:gen_4_1
            assign level_4_1_max[i*DATA_WIDTH+:DATA_WIDTH] = (level_4_r[(16-i)*DATA_WIDTH-1-:DATA_WIDTH] >level_4_r[i*DATA_WIDTH+:DATA_WIDTH]) ? level_4_r[(16-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_4_r[i*DATA_WIDTH+:DATA_WIDTH];   
            assign level_4_1_min[i*DATA_WIDTH+:DATA_WIDTH] = (level_4_r[(16-i)*DATA_WIDTH-1-:DATA_WIDTH] >level_4_r[i*DATA_WIDTH+:DATA_WIDTH]) ?  level_4_r[i*DATA_WIDTH+:DATA_WIDTH] : level_4_r[(16-i)*DATA_WIDTH-1-:DATA_WIDTH];
        end
    endgenerate
    
    generate
    for (i=0;i<4;i=i+1)
        begin:gen_4_2
            assign level_4_2_max_max_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_4_1_max[(8-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_4_1_max[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_4_1_max[(8-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_4_1_max[(4-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_4_2_max_min_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_4_1_max[(8-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_4_1_max[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_4_1_max[(4-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_4_1_max[(8-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_4_2_min_max_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_4_1_min[(8-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_4_1_min[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_4_1_min[(8-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_4_1_min[(4-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_4_2_min_min_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_4_1_min[(8-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_4_1_min[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_4_1_min[(4-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_4_1_min[(8-i)*DATA_WIDTH-1-:DATA_WIDTH];           
        end
    endgenerate
    
    generate
    for (i=0;i<2;i=i+1)
        begin:gen_4_3
            assign level_4_3_max_max_max_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_4_2_max_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_4_2_max_max_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_4_2_max_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_4_2_max_max_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_4_3_max_max_min_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_4_2_max_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_4_2_max_max_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_4_2_max_max_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_4_2_max_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_4_3_max_min_max_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_4_2_max_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_4_2_max_min_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_4_2_max_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_4_2_max_min_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_4_3_max_min_min_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_4_2_max_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_4_2_max_min_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_4_2_max_min_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_4_2_max_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_4_3_min_max_max_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_4_2_min_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_4_2_min_max_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_4_2_min_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_4_2_min_max_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_4_3_min_max_min_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_4_2_min_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_4_2_min_max_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_4_2_min_max_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_4_2_min_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_4_3_min_min_max_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_4_2_min_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_4_2_min_min_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_4_2_min_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_4_2_min_min_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_4_3_min_min_min_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_4_2_min_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_4_2_min_min_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_4_2_min_min_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_4_2_min_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH];
        end
    endgenerate
    
    assign level_4_3_max_max_max = (level_4_3_max_max_max_t[0+:DATA_WIDTH]>level_4_3_max_max_max_t[DATA_WIDTH+:DATA_WIDTH]) ? level_4_3_max_max_max_t : {level_4_3_max_max_max_t[0+:DATA_WIDTH],level_4_3_max_max_max_t[DATA_WIDTH+:DATA_WIDTH]};
    assign level_4_3_max_max_min = (level_4_3_max_max_min_t[0+:DATA_WIDTH]>level_4_3_max_max_min_t[DATA_WIDTH+:DATA_WIDTH]) ? level_4_3_max_max_min_t : {level_4_3_max_max_min_t[0+:DATA_WIDTH],level_4_3_max_max_min_t[DATA_WIDTH+:DATA_WIDTH]};
    assign level_4_3_max_min_max = (level_4_3_max_min_max_t[0+:DATA_WIDTH]>level_4_3_max_min_max_t[DATA_WIDTH+:DATA_WIDTH]) ? level_4_3_max_min_max_t : {level_4_3_max_min_max_t[0+:DATA_WIDTH],level_4_3_max_min_max_t[DATA_WIDTH+:DATA_WIDTH]};
    assign level_4_3_max_min_min = (level_4_3_max_min_min_t[0+:DATA_WIDTH]>level_4_3_max_min_min_t[DATA_WIDTH+:DATA_WIDTH]) ? level_4_3_max_min_min_t : {level_4_3_max_min_min_t[0+:DATA_WIDTH],level_4_3_max_min_min_t[DATA_WIDTH+:DATA_WIDTH]};
    assign level_4_3_min_max_max = (level_4_3_min_max_max_t[0+:DATA_WIDTH]>level_4_3_min_max_max_t[DATA_WIDTH+:DATA_WIDTH]) ? level_4_3_min_max_max_t : {level_4_3_min_max_max_t[0+:DATA_WIDTH],level_4_3_min_max_max_t[DATA_WIDTH+:DATA_WIDTH]};
    assign level_4_3_min_max_min = (level_4_3_min_max_min_t[0+:DATA_WIDTH]>level_4_3_min_max_min_t[DATA_WIDTH+:DATA_WIDTH]) ? level_4_3_min_max_min_t : {level_4_3_min_max_min_t[0+:DATA_WIDTH],level_4_3_min_max_min_t[DATA_WIDTH+:DATA_WIDTH]};
    assign level_4_3_min_min_max = (level_4_3_min_min_max_t[0+:DATA_WIDTH]>level_4_3_min_min_max_t[DATA_WIDTH+:DATA_WIDTH]) ? level_4_3_min_min_max_t : {level_4_3_min_min_max_t[0+:DATA_WIDTH],level_4_3_min_min_max_t[DATA_WIDTH+:DATA_WIDTH]};
    assign level_4_3_min_min_min = (level_4_3_min_min_min_t[0+:DATA_WIDTH]>level_4_3_min_min_min_t[DATA_WIDTH+:DATA_WIDTH]) ? level_4_3_min_min_min_t : {level_4_3_min_min_min_t[0+:DATA_WIDTH],level_4_3_min_min_min_t[DATA_WIDTH+:DATA_WIDTH]};
   
    assign level_4_w = {level_4_3_min_min_min,level_4_3_min_min_max,
                                 level_4_3_min_max_min,level_4_3_min_max_max,
                                 level_4_3_max_min_min,level_4_3_max_min_max,
                                 level_4_3_max_max_min,level_4_3_max_max_max};
    
    always@(posedge clk or negedge rst_n)
    begin
        if (!rst_n)
            level_4_r <= 'd0;
        else if(level_3_c_valid[1] && !ascend_3)
            level_4_r <= {level_4_r[0+:8*DATA_WIDTH],level_3_c_r};
        else
            level_4_r <= level_4_r;
    end
    
    always@(posedge clk or negedge rst_n)
    begin
        if(!rst_n)
            level_4_c_r <= 'd0;
        else
            level_4_c_r <= level_4_w;
    end
    
    always@(posedge clk or negedge rst_n)
    begin
        if(!rst_n)
            ascend_4 <= 1'b0;
        else if(level_3_c_valid[1] && !ascend_3)
            ascend_4 <= ~ascend_4;
    end
    
    always@(posedge clk or negedge rst_n)
    begin
        if (!rst_n)
            level_4_c_valid <= 'd0;
        else
            level_4_c_valid <= {level_4_c_valid[0],level_3_c_valid[1] & !ascend_3};
    end
    
    //构建第5级双调
    reg [32*DATA_WIDTH-1:0] level_5_r;
    reg [32*DATA_WIDTH-1:0] level_5_c_r;
    reg ascend_5;
    reg [1:0] level_5_c_valid;
    wire [16*DATA_WIDTH-1:0] level_5_1_max;
    wire [16*DATA_WIDTH-1:0] level_5_1_min;
    
    wire [8*DATA_WIDTH-1:0] level_5_2_max_max_t;
    wire [8*DATA_WIDTH-1:0] level_5_2_max_min_t;
    wire [8*DATA_WIDTH-1:0] level_5_2_min_max_t;
    wire [8*DATA_WIDTH-1:0] level_5_2_min_min_t;
    
    wire [4*DATA_WIDTH-1:0] level_5_3_max_max_max_t;
    wire [4*DATA_WIDTH-1:0] level_5_3_max_max_min_t;
    wire [4*DATA_WIDTH-1:0] level_5_3_max_min_max_t;
    wire [4*DATA_WIDTH-1:0] level_5_3_max_min_min_t;
    wire [4*DATA_WIDTH-1:0] level_5_3_min_max_max_t;
    wire [4*DATA_WIDTH-1:0] level_5_3_min_max_min_t;
    wire [4*DATA_WIDTH-1:0] level_5_3_min_min_max_t;
    wire [4*DATA_WIDTH-1:0] level_5_3_min_min_min_t;
    
    wire [2*DATA_WIDTH-1:0] level_5_4_max_max_max_max_t;
    wire [2*DATA_WIDTH-1:0] level_5_4_max_max_max_min_t;
    wire [2*DATA_WIDTH-1:0] level_5_4_max_max_min_max_t;
    wire [2*DATA_WIDTH-1:0] level_5_4_max_max_min_min_t;
    wire [2*DATA_WIDTH-1:0] level_5_4_max_min_max_max_t;
    wire [2*DATA_WIDTH-1:0] level_5_4_max_min_max_min_t;
    wire [2*DATA_WIDTH-1:0] level_5_4_max_min_min_max_t;
    wire [2*DATA_WIDTH-1:0] level_5_4_max_min_min_min_t;
    wire [2*DATA_WIDTH-1:0] level_5_4_min_max_max_max_t;
    wire [2*DATA_WIDTH-1:0] level_5_4_min_max_max_min_t;
    wire [2*DATA_WIDTH-1:0] level_5_4_min_max_min_max_t;
    wire [2*DATA_WIDTH-1:0] level_5_4_min_max_min_min_t;
    wire [2*DATA_WIDTH-1:0] level_5_4_min_min_max_max_t;
    wire [2*DATA_WIDTH-1:0] level_5_4_min_min_max_min_t;
    wire [2*DATA_WIDTH-1:0] level_5_4_min_min_min_max_t;
    wire [2*DATA_WIDTH-1:0] level_5_4_min_min_min_min_t;
    
    wire [2*DATA_WIDTH-1:0] level_5_4_max_max_max_max;
    wire [2*DATA_WIDTH-1:0] level_5_4_max_max_max_min;
    wire [2*DATA_WIDTH-1:0] level_5_4_max_max_min_max;
    wire [2*DATA_WIDTH-1:0] level_5_4_max_max_min_min;
    wire [2*DATA_WIDTH-1:0] level_5_4_max_min_max_max;
    wire [2*DATA_WIDTH-1:0] level_5_4_max_min_max_min;
    wire [2*DATA_WIDTH-1:0] level_5_4_max_min_min_max;
    wire [2*DATA_WIDTH-1:0] level_5_4_max_min_min_min;
    wire [2*DATA_WIDTH-1:0] level_5_4_min_max_max_max;
    wire [2*DATA_WIDTH-1:0] level_5_4_min_max_max_min;
    wire [2*DATA_WIDTH-1:0] level_5_4_min_max_min_max;
    wire [2*DATA_WIDTH-1:0] level_5_4_min_max_min_min;
    wire [2*DATA_WIDTH-1:0] level_5_4_min_min_max_max;
    wire [2*DATA_WIDTH-1:0] level_5_4_min_min_max_min;
    wire [2*DATA_WIDTH-1:0] level_5_4_min_min_min_max;
    wire [2*DATA_WIDTH-1:0] level_5_4_min_min_min_min;
    wire [32*DATA_WIDTH-1:0] level_5_w;
    
    generate
    for (i=0;i<16;i=i+1)
        begin:gen_5_1
            assign level_5_1_max[i*DATA_WIDTH+:DATA_WIDTH] = (level_5_r[(32-i)*DATA_WIDTH-1-:DATA_WIDTH] >level_5_r[i*DATA_WIDTH+:DATA_WIDTH]) ? level_5_r[(32-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_5_r[i*DATA_WIDTH+:DATA_WIDTH];   
            assign level_5_1_min[i*DATA_WIDTH+:DATA_WIDTH] = (level_5_r[(32-i)*DATA_WIDTH-1-:DATA_WIDTH] >level_5_r[i*DATA_WIDTH+:DATA_WIDTH]) ?  level_5_r[i*DATA_WIDTH+:DATA_WIDTH] : level_5_r[(32-i)*DATA_WIDTH-1-:DATA_WIDTH];
        end
    endgenerate
    
    generate
    for (i=0;i<8;i=i+1)
        begin:gen_5_2
            assign level_5_2_max_max_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_5_1_max[(16-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_5_1_max[(8-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_5_1_max[(16-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_5_1_max[(8-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_5_2_max_min_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_5_1_max[(16-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_5_1_max[(8-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_5_1_max[(8-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_5_1_max[(16-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_5_2_min_max_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_5_1_min[(16-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_5_1_min[(8-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_5_1_min[(16-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_5_1_min[(8-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_5_2_min_min_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_5_1_min[(16-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_5_1_min[(8-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_5_1_min[(8-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_5_1_min[(16-i)*DATA_WIDTH-1-:DATA_WIDTH];           
        end
    endgenerate
    
    generate
    for (i=0;i<4;i=i+1)
        begin:gen_5_3
            assign level_5_3_max_max_max_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_5_2_max_max_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_5_2_max_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_5_2_max_max_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_5_2_max_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_5_3_max_max_min_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_5_2_max_max_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_5_2_max_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_5_2_max_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_5_2_max_max_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_5_3_max_min_max_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_5_2_max_min_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_5_2_max_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_5_2_max_min_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_5_2_max_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_5_3_max_min_min_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_5_2_max_min_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_5_2_max_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_5_2_max_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_5_2_max_min_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_5_3_min_max_max_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_5_2_min_max_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_5_2_min_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_5_2_min_max_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_5_2_min_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_5_3_min_max_min_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_5_2_min_max_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_5_2_min_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_5_2_min_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_5_2_min_max_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_5_3_min_min_max_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_5_2_min_min_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_5_2_min_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_5_2_min_min_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_5_2_min_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_5_3_min_min_min_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_5_2_min_min_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_5_2_min_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_5_2_min_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_5_2_min_min_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH];
        end
    endgenerate
    
    generate
    for (i=0;i<2;i=i+1)
        begin:gen_5_4
            assign level_5_4_max_max_max_max_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_5_3_max_max_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_5_3_max_max_max_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_5_3_max_max_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_5_3_max_max_max_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_5_4_max_max_max_min_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_5_3_max_max_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_5_3_max_max_max_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_5_3_max_max_max_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_5_3_max_max_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_5_4_max_max_min_max_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_5_3_max_max_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_5_3_max_max_min_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_5_3_max_max_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_5_3_max_max_min_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_5_4_max_max_min_min_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_5_3_max_max_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_5_3_max_max_min_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_5_3_max_max_min_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_5_3_max_max_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_5_4_max_min_max_max_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_5_3_max_min_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_5_3_max_min_max_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_5_3_max_min_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_5_3_max_min_max_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_5_4_max_min_max_min_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_5_3_max_min_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_5_3_max_min_max_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_5_3_max_min_max_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_5_3_max_min_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_5_4_max_min_min_max_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_5_3_max_min_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_5_3_max_min_min_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_5_3_max_min_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_5_3_max_min_min_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_5_4_max_min_min_min_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_5_3_max_min_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_5_3_max_min_min_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_5_3_max_min_min_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_5_3_max_min_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH];          
            assign level_5_4_min_max_max_max_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_5_3_min_max_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_5_3_min_max_max_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_5_3_min_max_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_5_3_min_max_max_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_5_4_min_max_max_min_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_5_3_min_max_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_5_3_min_max_max_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_5_3_min_max_max_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_5_3_min_max_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_5_4_min_max_min_max_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_5_3_min_max_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_5_3_min_max_min_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_5_3_min_max_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_5_3_min_max_min_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_5_4_min_max_min_min_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_5_3_min_max_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_5_3_min_max_min_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_5_3_min_max_min_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_5_3_min_max_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_5_4_min_min_max_max_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_5_3_min_min_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_5_3_min_min_max_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_5_3_min_min_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_5_3_min_min_max_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_5_4_min_min_max_min_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_5_3_min_min_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_5_3_min_min_max_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_5_3_min_min_max_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_5_3_min_min_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_5_4_min_min_min_max_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_5_3_min_min_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_5_3_min_min_min_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_5_3_min_min_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_5_3_min_min_min_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_5_4_min_min_min_min_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_5_3_min_min_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_5_3_min_min_min_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_5_3_min_min_min_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_5_3_min_min_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH];
        end
    endgenerate    
    
    assign level_5_4_max_max_max_max = (level_5_4_max_max_max_max_t[0+:DATA_WIDTH]>level_5_4_max_max_max_max_t[DATA_WIDTH+:DATA_WIDTH]) ? level_5_4_max_max_max_max_t : {level_5_4_max_max_max_max_t[0+:DATA_WIDTH],level_5_4_max_max_max_max_t[DATA_WIDTH+:DATA_WIDTH]};
    assign level_5_4_max_max_max_min = (level_5_4_max_max_max_min_t[0+:DATA_WIDTH]>level_5_4_max_max_max_min_t[DATA_WIDTH+:DATA_WIDTH]) ? level_5_4_max_max_max_min_t : {level_5_4_max_max_max_min_t[0+:DATA_WIDTH],level_5_4_max_max_max_min_t[DATA_WIDTH+:DATA_WIDTH]};
    assign level_5_4_max_max_min_max = (level_5_4_max_max_min_max_t[0+:DATA_WIDTH]>level_5_4_max_max_min_max_t[DATA_WIDTH+:DATA_WIDTH]) ? level_5_4_max_max_min_max_t : {level_5_4_max_max_min_max_t[0+:DATA_WIDTH],level_5_4_max_max_min_max_t[DATA_WIDTH+:DATA_WIDTH]};
    assign level_5_4_max_max_min_min = (level_5_4_max_max_min_min_t[0+:DATA_WIDTH]>level_5_4_max_max_min_min_t[DATA_WIDTH+:DATA_WIDTH]) ? level_5_4_max_max_min_min_t : {level_5_4_max_max_min_min_t[0+:DATA_WIDTH],level_5_4_max_max_min_min_t[DATA_WIDTH+:DATA_WIDTH]};
    assign level_5_4_max_min_max_max = (level_5_4_max_min_max_max_t[0+:DATA_WIDTH]>level_5_4_max_min_max_max_t[DATA_WIDTH+:DATA_WIDTH]) ? level_5_4_max_min_max_max_t : {level_5_4_max_min_max_max_t[0+:DATA_WIDTH],level_5_4_max_min_max_max_t[DATA_WIDTH+:DATA_WIDTH]};
    assign level_5_4_max_min_max_min = (level_5_4_max_min_max_min_t[0+:DATA_WIDTH]>level_5_4_max_min_max_min_t[DATA_WIDTH+:DATA_WIDTH]) ? level_5_4_max_min_max_min_t : {level_5_4_max_min_max_min_t[0+:DATA_WIDTH],level_5_4_max_min_max_min_t[DATA_WIDTH+:DATA_WIDTH]};
    assign level_5_4_max_min_min_max = (level_5_4_max_min_min_max_t[0+:DATA_WIDTH]>level_5_4_max_min_min_max_t[DATA_WIDTH+:DATA_WIDTH]) ? level_5_4_max_min_min_max_t : {level_5_4_max_min_min_max_t[0+:DATA_WIDTH],level_5_4_max_min_min_max_t[DATA_WIDTH+:DATA_WIDTH]};
    assign level_5_4_max_min_min_min = (level_5_4_max_min_min_min_t[0+:DATA_WIDTH]>level_5_4_max_min_min_min_t[DATA_WIDTH+:DATA_WIDTH]) ? level_5_4_max_min_min_min_t : {level_5_4_max_min_min_min_t[0+:DATA_WIDTH],level_5_4_max_min_min_min_t[DATA_WIDTH+:DATA_WIDTH]};
    assign level_5_4_min_max_max_max = (level_5_4_min_max_max_max_t[0+:DATA_WIDTH]>level_5_4_min_max_max_max_t[DATA_WIDTH+:DATA_WIDTH]) ? level_5_4_min_max_max_max_t : {level_5_4_min_max_max_max_t[0+:DATA_WIDTH],level_5_4_min_max_max_max_t[DATA_WIDTH+:DATA_WIDTH]};
    assign level_5_4_min_max_max_min = (level_5_4_min_max_max_min_t[0+:DATA_WIDTH]>level_5_4_min_max_max_min_t[DATA_WIDTH+:DATA_WIDTH]) ? level_5_4_min_max_max_min_t : {level_5_4_min_max_max_min_t[0+:DATA_WIDTH],level_5_4_min_max_max_min_t[DATA_WIDTH+:DATA_WIDTH]};
    assign level_5_4_min_max_min_max = (level_5_4_min_max_min_max_t[0+:DATA_WIDTH]>level_5_4_min_max_min_max_t[DATA_WIDTH+:DATA_WIDTH]) ? level_5_4_min_max_min_max_t : {level_5_4_min_max_min_max_t[0+:DATA_WIDTH],level_5_4_min_max_min_max_t[DATA_WIDTH+:DATA_WIDTH]};
    assign level_5_4_min_max_min_min = (level_5_4_min_max_min_min_t[0+:DATA_WIDTH]>level_5_4_min_max_min_min_t[DATA_WIDTH+:DATA_WIDTH]) ? level_5_4_min_max_min_min_t : {level_5_4_min_max_min_min_t[0+:DATA_WIDTH],level_5_4_min_max_min_min_t[DATA_WIDTH+:DATA_WIDTH]};
    assign level_5_4_min_min_max_max = (level_5_4_min_min_max_max_t[0+:DATA_WIDTH]>level_5_4_min_min_max_max_t[DATA_WIDTH+:DATA_WIDTH]) ? level_5_4_min_min_max_max_t : {level_5_4_min_min_max_max_t[0+:DATA_WIDTH],level_5_4_min_min_max_max_t[DATA_WIDTH+:DATA_WIDTH]};
    assign level_5_4_min_min_max_min = (level_5_4_min_min_max_min_t[0+:DATA_WIDTH]>level_5_4_min_min_max_min_t[DATA_WIDTH+:DATA_WIDTH]) ? level_5_4_min_min_max_min_t : {level_5_4_min_min_max_min_t[0+:DATA_WIDTH],level_5_4_min_min_max_min_t[DATA_WIDTH+:DATA_WIDTH]};
    assign level_5_4_min_min_min_max = (level_5_4_min_min_min_max_t[0+:DATA_WIDTH]>level_5_4_min_min_min_max_t[DATA_WIDTH+:DATA_WIDTH]) ? level_5_4_min_min_min_max_t : {level_5_4_min_min_min_max_t[0+:DATA_WIDTH],level_5_4_min_min_min_max_t[DATA_WIDTH+:DATA_WIDTH]};
    assign level_5_4_min_min_min_min = (level_5_4_min_min_min_min_t[0+:DATA_WIDTH]>level_5_4_min_min_min_min_t[DATA_WIDTH+:DATA_WIDTH]) ? level_5_4_min_min_min_min_t : {level_5_4_min_min_min_min_t[0+:DATA_WIDTH],level_5_4_min_min_min_min_t[DATA_WIDTH+:DATA_WIDTH]};

    assign level_5_w = {level_5_4_min_min_min_min,level_5_4_min_min_min_max,
                                 level_5_4_min_min_max_min,level_5_4_min_min_max_max,
                                 level_5_4_min_max_min_min,level_5_4_min_max_min_max,
                                 level_5_4_min_max_max_min,level_5_4_min_max_max_max,
                                 level_5_4_max_min_min_min,level_5_4_max_min_min_max,
                                 level_5_4_max_min_max_min,level_5_4_max_min_max_max,
                                 level_5_4_max_max_min_min,level_5_4_max_max_min_max,
                                 level_5_4_max_max_max_min,level_5_4_max_max_max_max};
    
    always@(posedge clk or negedge rst_n)
    begin
        if (!rst_n)
            level_5_r <= 'd0;
        else if(level_4_c_valid[1] && !ascend_4)
            level_5_r <= {level_5_r[0+:16*DATA_WIDTH],level_4_c_r};
        else
            level_5_r <= level_5_r;
    end
    
    always@(posedge clk or negedge rst_n)
    begin
        if(!rst_n)
            level_5_c_r <= 'd0;
        else
            level_5_c_r <= level_5_w;
    end
    
    always@(posedge clk or negedge rst_n)
    begin
        if(!rst_n)
            ascend_5 <= 1'b0;
        else if(level_4_c_valid[1] && !ascend_4)
            ascend_5 <= ~ascend_5;
    end
    
    always@(posedge clk or negedge rst_n)
    begin
        if (!rst_n)
            level_5_c_valid <= 'd0;
        else
            level_5_c_valid <= {level_5_c_valid[0],level_4_c_valid[1] & !ascend_4};
    end
    
    //构建第6级双调
    reg [64*DATA_WIDTH-1:0] level_6_r;
    reg [64*DATA_WIDTH-1:0] level_6_c_r;
    reg ascend_6;
    reg [1:0] level_6_c_valid;
    wire [32*DATA_WIDTH-1:0] level_6_1_max;
    wire [32*DATA_WIDTH-1:0] level_6_1_min;
    
    wire [16*DATA_WIDTH-1:0] level_6_2_max_max_t;
    wire [16*DATA_WIDTH-1:0] level_6_2_max_min_t;
    wire [16*DATA_WIDTH-1:0] level_6_2_min_max_t;
    wire [16*DATA_WIDTH-1:0] level_6_2_min_min_t;
    
    wire [8*DATA_WIDTH-1:0] level_6_3_max_max_max_t;
    wire [8*DATA_WIDTH-1:0] level_6_3_max_max_min_t;
    wire [8*DATA_WIDTH-1:0] level_6_3_max_min_max_t;
    wire [8*DATA_WIDTH-1:0] level_6_3_max_min_min_t;
    wire [8*DATA_WIDTH-1:0] level_6_3_min_max_max_t;
    wire [8*DATA_WIDTH-1:0] level_6_3_min_max_min_t;
    wire [8*DATA_WIDTH-1:0] level_6_3_min_min_max_t;
    wire [8*DATA_WIDTH-1:0] level_6_3_min_min_min_t;
    
    wire [4*DATA_WIDTH-1:0] level_6_4_max_max_max_max_t;
    wire [4*DATA_WIDTH-1:0] level_6_4_max_max_max_min_t;
    wire [4*DATA_WIDTH-1:0] level_6_4_max_max_min_max_t;
    wire [4*DATA_WIDTH-1:0] level_6_4_max_max_min_min_t;
    wire [4*DATA_WIDTH-1:0] level_6_4_max_min_max_max_t;
    wire [4*DATA_WIDTH-1:0] level_6_4_max_min_max_min_t;
    wire [4*DATA_WIDTH-1:0] level_6_4_max_min_min_max_t;
    wire [4*DATA_WIDTH-1:0] level_6_4_max_min_min_min_t;
    wire [4*DATA_WIDTH-1:0] level_6_4_min_max_max_max_t;
    wire [4*DATA_WIDTH-1:0] level_6_4_min_max_max_min_t;
    wire [4*DATA_WIDTH-1:0] level_6_4_min_max_min_max_t;
    wire [4*DATA_WIDTH-1:0] level_6_4_min_max_min_min_t;
    wire [4*DATA_WIDTH-1:0] level_6_4_min_min_max_max_t;
    wire [4*DATA_WIDTH-1:0] level_6_4_min_min_max_min_t;
    wire [4*DATA_WIDTH-1:0] level_6_4_min_min_min_max_t;
    wire [4*DATA_WIDTH-1:0] level_6_4_min_min_min_min_t;
    
    wire [2*DATA_WIDTH-1:0] level_6_5_max_max_max_max_max_t;
    wire [2*DATA_WIDTH-1:0] level_6_5_max_max_max_max_min_t;   
    wire [2*DATA_WIDTH-1:0] level_6_5_max_max_max_min_max_t;
    wire [2*DATA_WIDTH-1:0] level_6_5_max_max_max_min_min_t;
    wire [2*DATA_WIDTH-1:0] level_6_5_max_max_min_max_max_t;
    wire [2*DATA_WIDTH-1:0] level_6_5_max_max_min_max_min_t;
    wire [2*DATA_WIDTH-1:0] level_6_5_max_max_min_min_max_t;
    wire [2*DATA_WIDTH-1:0] level_6_5_max_max_min_min_min_t;
    wire [2*DATA_WIDTH-1:0] level_6_5_max_min_max_max_max_t;
    wire [2*DATA_WIDTH-1:0] level_6_5_max_min_max_max_min_t;
    wire [2*DATA_WIDTH-1:0] level_6_5_max_min_max_min_max_t;
    wire [2*DATA_WIDTH-1:0] level_6_5_max_min_max_min_min_t;
    wire [2*DATA_WIDTH-1:0] level_6_5_max_min_min_max_max_t;
    wire [2*DATA_WIDTH-1:0] level_6_5_max_min_min_max_min_t;
    wire [2*DATA_WIDTH-1:0] level_6_5_max_min_min_min_max_t;
    wire [2*DATA_WIDTH-1:0] level_6_5_max_min_min_min_min_t;
    wire [2*DATA_WIDTH-1:0] level_6_5_min_max_max_max_max_t;
    wire [2*DATA_WIDTH-1:0] level_6_5_min_max_max_max_min_t;
    wire [2*DATA_WIDTH-1:0] level_6_5_min_max_max_min_max_t;
    wire [2*DATA_WIDTH-1:0] level_6_5_min_max_max_min_min_t;
    wire [2*DATA_WIDTH-1:0] level_6_5_min_max_min_max_max_t;
    wire [2*DATA_WIDTH-1:0] level_6_5_min_max_min_max_min_t;
    wire [2*DATA_WIDTH-1:0] level_6_5_min_max_min_min_max_t;
    wire [2*DATA_WIDTH-1:0] level_6_5_min_max_min_min_min_t;
    wire [2*DATA_WIDTH-1:0] level_6_5_min_min_max_max_max_t;
    wire [2*DATA_WIDTH-1:0] level_6_5_min_min_max_max_min_t;
    wire [2*DATA_WIDTH-1:0] level_6_5_min_min_max_min_max_t;
    wire [2*DATA_WIDTH-1:0] level_6_5_min_min_max_min_min_t;
    wire [2*DATA_WIDTH-1:0] level_6_5_min_min_min_max_max_t;
    wire [2*DATA_WIDTH-1:0] level_6_5_min_min_min_max_min_t;
    wire [2*DATA_WIDTH-1:0] level_6_5_min_min_min_min_max_t;
    wire [2*DATA_WIDTH-1:0] level_6_5_min_min_min_min_min_t;

    wire [2*DATA_WIDTH-1:0] level_6_5_max_max_max_max_max;
    wire [2*DATA_WIDTH-1:0] level_6_5_max_max_max_max_min;       
    wire [2*DATA_WIDTH-1:0] level_6_5_max_max_max_min_max;
    wire [2*DATA_WIDTH-1:0] level_6_5_max_max_max_min_min;
    wire [2*DATA_WIDTH-1:0] level_6_5_max_max_min_max_max;
    wire [2*DATA_WIDTH-1:0] level_6_5_max_max_min_max_min;
    wire [2*DATA_WIDTH-1:0] level_6_5_max_max_min_min_max;
    wire [2*DATA_WIDTH-1:0] level_6_5_max_max_min_min_min;
    wire [2*DATA_WIDTH-1:0] level_6_5_max_min_max_max_max;
    wire [2*DATA_WIDTH-1:0] level_6_5_max_min_max_max_min;
    wire [2*DATA_WIDTH-1:0] level_6_5_max_min_max_min_max;
    wire [2*DATA_WIDTH-1:0] level_6_5_max_min_max_min_min;
    wire [2*DATA_WIDTH-1:0] level_6_5_max_min_min_max_max;
    wire [2*DATA_WIDTH-1:0] level_6_5_max_min_min_max_min;
    wire [2*DATA_WIDTH-1:0] level_6_5_max_min_min_min_max;
    wire [2*DATA_WIDTH-1:0] level_6_5_max_min_min_min_min;
    wire [2*DATA_WIDTH-1:0] level_6_5_min_max_max_max_max;
    wire [2*DATA_WIDTH-1:0] level_6_5_min_max_max_max_min;
    wire [2*DATA_WIDTH-1:0] level_6_5_min_max_max_min_max;
    wire [2*DATA_WIDTH-1:0] level_6_5_min_max_max_min_min;
    wire [2*DATA_WIDTH-1:0] level_6_5_min_max_min_max_max;
    wire [2*DATA_WIDTH-1:0] level_6_5_min_max_min_max_min;
    wire [2*DATA_WIDTH-1:0] level_6_5_min_max_min_min_max;
    wire [2*DATA_WIDTH-1:0] level_6_5_min_max_min_min_min;
    wire [2*DATA_WIDTH-1:0] level_6_5_min_min_max_max_max;
    wire [2*DATA_WIDTH-1:0] level_6_5_min_min_max_max_min;
    wire [2*DATA_WIDTH-1:0] level_6_5_min_min_max_min_max;
    wire [2*DATA_WIDTH-1:0] level_6_5_min_min_max_min_min;
    wire [2*DATA_WIDTH-1:0] level_6_5_min_min_min_max_max;
    wire [2*DATA_WIDTH-1:0] level_6_5_min_min_min_max_min;
    wire [2*DATA_WIDTH-1:0] level_6_5_min_min_min_min_max;
    wire [2*DATA_WIDTH-1:0] level_6_5_min_min_min_min_min;

    wire [64*DATA_WIDTH-1:0] level_6_w;
    
    generate
    for (i=0;i<32;i=i+1)
        begin:gen_6_1
            assign level_6_1_max[i*DATA_WIDTH+:DATA_WIDTH] = (level_6_r[(64-i)*DATA_WIDTH-1-:DATA_WIDTH] >level_6_r[i*DATA_WIDTH+:DATA_WIDTH]) ? level_6_r[(64-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_6_r[i*DATA_WIDTH+:DATA_WIDTH];   
            assign level_6_1_min[i*DATA_WIDTH+:DATA_WIDTH] = (level_6_r[(64-i)*DATA_WIDTH-1-:DATA_WIDTH] >level_6_r[i*DATA_WIDTH+:DATA_WIDTH]) ?  level_6_r[i*DATA_WIDTH+:DATA_WIDTH] : level_6_r[(64-i)*DATA_WIDTH-1-:DATA_WIDTH];
        end
    endgenerate
    
    generate
    for (i=0;i<16;i=i+1)
        begin:gen_6_2
            assign level_6_2_max_max_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_6_1_max[(32-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_6_1_max[(16-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_6_1_max[(32-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_6_1_max[(16-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_6_2_max_min_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_6_1_max[(32-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_6_1_max[(16-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_6_1_max[(16-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_6_1_max[(32-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_6_2_min_max_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_6_1_min[(32-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_6_1_min[(16-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_6_1_min[(32-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_6_1_min[(16-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_6_2_min_min_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_6_1_min[(32-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_6_1_min[(16-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_6_1_min[(16-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_6_1_min[(32-i)*DATA_WIDTH-1-:DATA_WIDTH];           
        end
    endgenerate
    
    generate
    for (i=0;i<8;i=i+1)
        begin:gen_6_3
            assign level_6_3_max_max_max_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_6_2_max_max_t[(16-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_6_2_max_max_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_6_2_max_max_t[(16-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_6_2_max_max_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_6_3_max_max_min_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_6_2_max_max_t[(16-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_6_2_max_max_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_6_2_max_max_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_6_2_max_max_t[(16-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_6_3_max_min_max_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_6_2_max_min_t[(16-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_6_2_max_min_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_6_2_max_min_t[(16-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_6_2_max_min_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_6_3_max_min_min_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_6_2_max_min_t[(16-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_6_2_max_min_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_6_2_max_min_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_6_2_max_min_t[(16-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_6_3_min_max_max_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_6_2_min_max_t[(16-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_6_2_min_max_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_6_2_min_max_t[(16-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_6_2_min_max_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_6_3_min_max_min_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_6_2_min_max_t[(16-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_6_2_min_max_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_6_2_min_max_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_6_2_min_max_t[(16-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_6_3_min_min_max_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_6_2_min_min_t[(16-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_6_2_min_min_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_6_2_min_min_t[(16-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_6_2_min_min_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_6_3_min_min_min_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_6_2_min_min_t[(16-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_6_2_min_min_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_6_2_min_min_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_6_2_min_min_t[(16-i)*DATA_WIDTH-1-:DATA_WIDTH];
        end
    endgenerate
    
    generate
    for (i=0;i<4;i=i+1)
        begin:gen_6_4
            assign level_6_4_max_max_max_max_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_6_3_max_max_max_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_6_3_max_max_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_6_3_max_max_max_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_6_3_max_max_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_6_4_max_max_max_min_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_6_3_max_max_max_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_6_3_max_max_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_6_3_max_max_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_6_3_max_max_max_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_6_4_max_max_min_max_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_6_3_max_max_min_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_6_3_max_max_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_6_3_max_max_min_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_6_3_max_max_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_6_4_max_max_min_min_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_6_3_max_max_min_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_6_3_max_max_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_6_3_max_max_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_6_3_max_max_min_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_6_4_max_min_max_max_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_6_3_max_min_max_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_6_3_max_min_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_6_3_max_min_max_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_6_3_max_min_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_6_4_max_min_max_min_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_6_3_max_min_max_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_6_3_max_min_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_6_3_max_min_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_6_3_max_min_max_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_6_4_max_min_min_max_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_6_3_max_min_min_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_6_3_max_min_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_6_3_max_min_min_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_6_3_max_min_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_6_4_max_min_min_min_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_6_3_max_min_min_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_6_3_max_min_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_6_3_max_min_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_6_3_max_min_min_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH];          
            assign level_6_4_min_max_max_max_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_6_3_min_max_max_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_6_3_min_max_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_6_3_min_max_max_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_6_3_min_max_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_6_4_min_max_max_min_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_6_3_min_max_max_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_6_3_min_max_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_6_3_min_max_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_6_3_min_max_max_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_6_4_min_max_min_max_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_6_3_min_max_min_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_6_3_min_max_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_6_3_min_max_min_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_6_3_min_max_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_6_4_min_max_min_min_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_6_3_min_max_min_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_6_3_min_max_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_6_3_min_max_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_6_3_min_max_min_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_6_4_min_min_max_max_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_6_3_min_min_max_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_6_3_min_min_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_6_3_min_min_max_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_6_3_min_min_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_6_4_min_min_max_min_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_6_3_min_min_max_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_6_3_min_min_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_6_3_min_min_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_6_3_min_min_max_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_6_4_min_min_min_max_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_6_3_min_min_min_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_6_3_min_min_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_6_3_min_min_min_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_6_3_min_min_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_6_4_min_min_min_min_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_6_3_min_min_min_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_6_3_min_min_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_6_3_min_min_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_6_3_min_min_min_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH];
        end
    endgenerate    
    
    generate
    for (i=0;i<2;i=i+1)
        begin:gen_6_5
            assign level_6_5_max_max_max_max_max_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_6_4_max_max_max_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_6_4_max_max_max_max_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_6_4_max_max_max_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_6_4_max_max_max_max_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_6_5_max_max_max_max_min_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_6_4_max_max_max_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_6_4_max_max_max_max_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_6_4_max_max_max_max_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_6_4_max_max_max_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_6_5_max_max_max_min_max_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_6_4_max_max_max_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_6_4_max_max_max_min_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_6_4_max_max_max_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_6_4_max_max_max_min_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_6_5_max_max_max_min_min_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_6_4_max_max_max_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_6_4_max_max_max_min_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_6_4_max_max_max_min_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_6_4_max_max_max_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_6_5_max_max_min_max_max_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_6_4_max_max_min_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_6_4_max_max_min_max_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_6_4_max_max_min_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_6_4_max_max_min_max_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_6_5_max_max_min_max_min_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_6_4_max_max_min_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_6_4_max_max_min_max_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_6_4_max_max_min_max_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_6_4_max_max_min_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_6_5_max_max_min_min_max_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_6_4_max_max_min_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_6_4_max_max_min_min_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_6_4_max_max_min_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_6_4_max_max_min_min_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_6_5_max_max_min_min_min_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_6_4_max_max_min_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_6_4_max_max_min_min_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_6_4_max_max_min_min_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_6_4_max_max_min_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH];          
            assign level_6_5_max_min_max_max_max_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_6_4_max_min_max_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_6_4_max_min_max_max_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_6_4_max_min_max_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_6_4_max_min_max_max_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_6_5_max_min_max_max_min_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_6_4_max_min_max_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_6_4_max_min_max_max_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_6_4_max_min_max_max_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_6_4_max_min_max_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_6_5_max_min_max_min_max_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_6_4_max_min_max_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_6_4_max_min_max_min_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_6_4_max_min_max_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_6_4_max_min_max_min_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_6_5_max_min_max_min_min_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_6_4_max_min_max_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_6_4_max_min_max_min_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_6_4_max_min_max_min_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_6_4_max_min_max_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_6_5_max_min_min_max_max_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_6_4_max_min_min_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_6_4_max_min_min_max_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_6_4_max_min_min_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_6_4_max_min_min_max_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_6_5_max_min_min_max_min_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_6_4_max_min_min_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_6_4_max_min_min_max_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_6_4_max_min_min_max_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_6_4_max_min_min_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_6_5_max_min_min_min_max_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_6_4_max_min_min_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_6_4_max_min_min_min_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_6_4_max_min_min_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_6_4_max_min_min_min_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_6_5_max_min_min_min_min_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_6_4_max_min_min_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_6_4_max_min_min_min_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_6_4_max_min_min_min_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_6_4_max_min_min_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_6_5_min_max_max_max_max_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_6_4_min_max_max_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_6_4_min_max_max_max_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_6_4_min_max_max_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_6_4_min_max_max_max_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_6_5_min_max_max_max_min_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_6_4_min_max_max_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_6_4_min_max_max_max_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_6_4_min_max_max_max_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_6_4_min_max_max_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_6_5_min_max_max_min_max_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_6_4_min_max_max_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_6_4_min_max_max_min_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_6_4_min_max_max_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_6_4_min_max_max_min_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_6_5_min_max_max_min_min_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_6_4_min_max_max_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_6_4_min_max_max_min_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_6_4_min_max_max_min_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_6_4_min_max_max_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_6_5_min_max_min_max_max_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_6_4_min_max_min_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_6_4_min_max_min_max_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_6_4_min_max_min_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_6_4_min_max_min_max_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_6_5_min_max_min_max_min_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_6_4_min_max_min_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_6_4_min_max_min_max_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_6_4_min_max_min_max_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_6_4_min_max_min_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_6_5_min_max_min_min_max_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_6_4_min_max_min_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_6_4_min_max_min_min_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_6_4_min_max_min_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_6_4_min_max_min_min_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_6_5_min_max_min_min_min_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_6_4_min_max_min_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_6_4_min_max_min_min_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_6_4_min_max_min_min_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_6_4_min_max_min_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH];          
            assign level_6_5_min_min_max_max_max_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_6_4_min_min_max_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_6_4_min_min_max_max_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_6_4_min_min_max_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_6_4_min_min_max_max_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_6_5_min_min_max_max_min_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_6_4_min_min_max_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_6_4_min_min_max_max_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_6_4_min_min_max_max_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_6_4_min_min_max_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_6_5_min_min_max_min_max_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_6_4_min_min_max_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_6_4_min_min_max_min_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_6_4_min_min_max_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_6_4_min_min_max_min_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_6_5_min_min_max_min_min_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_6_4_min_min_max_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_6_4_min_min_max_min_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_6_4_min_min_max_min_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_6_4_min_min_max_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_6_5_min_min_min_max_max_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_6_4_min_min_min_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_6_4_min_min_min_max_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_6_4_min_min_min_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_6_4_min_min_min_max_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_6_5_min_min_min_max_min_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_6_4_min_min_min_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_6_4_min_min_min_max_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_6_4_min_min_min_max_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_6_4_min_min_min_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_6_5_min_min_min_min_max_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_6_4_min_min_min_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_6_4_min_min_min_min_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_6_4_min_min_min_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_6_4_min_min_min_min_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_6_5_min_min_min_min_min_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_6_4_min_min_min_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_6_4_min_min_min_min_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_6_4_min_min_min_min_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_6_4_min_min_min_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH];

        end
    endgenerate 
    
    assign level_6_5_max_max_max_max_max = (level_6_5_max_max_max_max_max_t[0+:DATA_WIDTH]>level_6_5_max_max_max_max_max_t[DATA_WIDTH+:DATA_WIDTH]) ? level_6_5_max_max_max_max_max_t : {level_6_5_max_max_max_max_max_t[0+:DATA_WIDTH],level_6_5_max_max_max_max_max_t[DATA_WIDTH+:DATA_WIDTH]};
    assign level_6_5_max_max_max_max_min = (level_6_5_max_max_max_max_min_t[0+:DATA_WIDTH]>level_6_5_max_max_max_max_min_t[DATA_WIDTH+:DATA_WIDTH]) ? level_6_5_max_max_max_max_min_t : {level_6_5_max_max_max_max_min_t[0+:DATA_WIDTH],level_6_5_max_max_max_max_min_t[DATA_WIDTH+:DATA_WIDTH]};
    assign level_6_5_max_max_max_min_max = (level_6_5_max_max_max_min_max_t[0+:DATA_WIDTH]>level_6_5_max_max_max_min_max_t[DATA_WIDTH+:DATA_WIDTH]) ? level_6_5_max_max_max_min_max_t : {level_6_5_max_max_max_min_max_t[0+:DATA_WIDTH],level_6_5_max_max_max_min_max_t[DATA_WIDTH+:DATA_WIDTH]};
    assign level_6_5_max_max_max_min_min = (level_6_5_max_max_max_min_min_t[0+:DATA_WIDTH]>level_6_5_max_max_max_min_min_t[DATA_WIDTH+:DATA_WIDTH]) ? level_6_5_max_max_max_min_min_t : {level_6_5_max_max_max_min_min_t[0+:DATA_WIDTH],level_6_5_max_max_max_min_min_t[DATA_WIDTH+:DATA_WIDTH]};
    assign level_6_5_max_max_min_max_max = (level_6_5_max_max_min_max_max_t[0+:DATA_WIDTH]>level_6_5_max_max_min_max_max_t[DATA_WIDTH+:DATA_WIDTH]) ? level_6_5_max_max_min_max_max_t : {level_6_5_max_max_min_max_max_t[0+:DATA_WIDTH],level_6_5_max_max_min_max_max_t[DATA_WIDTH+:DATA_WIDTH]};
    assign level_6_5_max_max_min_max_min = (level_6_5_max_max_min_max_min_t[0+:DATA_WIDTH]>level_6_5_max_max_min_max_min_t[DATA_WIDTH+:DATA_WIDTH]) ? level_6_5_max_max_min_max_min_t : {level_6_5_max_max_min_max_min_t[0+:DATA_WIDTH],level_6_5_max_max_min_max_min_t[DATA_WIDTH+:DATA_WIDTH]};
    assign level_6_5_max_max_min_min_max = (level_6_5_max_max_min_min_max_t[0+:DATA_WIDTH]>level_6_5_max_max_min_min_max_t[DATA_WIDTH+:DATA_WIDTH]) ? level_6_5_max_max_min_min_max_t : {level_6_5_max_max_min_min_max_t[0+:DATA_WIDTH],level_6_5_max_max_min_min_max_t[DATA_WIDTH+:DATA_WIDTH]};
    assign level_6_5_max_max_min_min_min = (level_6_5_max_max_min_min_min_t[0+:DATA_WIDTH]>level_6_5_max_max_min_min_min_t[DATA_WIDTH+:DATA_WIDTH]) ? level_6_5_max_max_min_min_min_t : {level_6_5_max_max_min_min_min_t[0+:DATA_WIDTH],level_6_5_max_max_min_min_min_t[DATA_WIDTH+:DATA_WIDTH]};
    assign level_6_5_max_min_max_max_max = (level_6_5_max_min_max_max_max_t[0+:DATA_WIDTH]>level_6_5_max_min_max_max_max_t[DATA_WIDTH+:DATA_WIDTH]) ? level_6_5_max_min_max_max_max_t : {level_6_5_max_min_max_max_max_t[0+:DATA_WIDTH],level_6_5_max_min_max_max_max_t[DATA_WIDTH+:DATA_WIDTH]};
    assign level_6_5_max_min_max_max_min = (level_6_5_max_min_max_max_min_t[0+:DATA_WIDTH]>level_6_5_max_min_max_max_min_t[DATA_WIDTH+:DATA_WIDTH]) ? level_6_5_max_min_max_max_min_t : {level_6_5_max_min_max_max_min_t[0+:DATA_WIDTH],level_6_5_max_min_max_max_min_t[DATA_WIDTH+:DATA_WIDTH]};
    assign level_6_5_max_min_max_min_max = (level_6_5_max_min_max_min_max_t[0+:DATA_WIDTH]>level_6_5_max_min_max_min_max_t[DATA_WIDTH+:DATA_WIDTH]) ? level_6_5_max_min_max_min_max_t : {level_6_5_max_min_max_min_max_t[0+:DATA_WIDTH],level_6_5_max_min_max_min_max_t[DATA_WIDTH+:DATA_WIDTH]};
    assign level_6_5_max_min_max_min_min = (level_6_5_max_min_max_min_min_t[0+:DATA_WIDTH]>level_6_5_max_min_max_min_min_t[DATA_WIDTH+:DATA_WIDTH]) ? level_6_5_max_min_max_min_min_t : {level_6_5_max_min_max_min_min_t[0+:DATA_WIDTH],level_6_5_max_min_max_min_min_t[DATA_WIDTH+:DATA_WIDTH]};
    assign level_6_5_max_min_min_max_max = (level_6_5_max_min_min_max_max_t[0+:DATA_WIDTH]>level_6_5_max_min_min_max_max_t[DATA_WIDTH+:DATA_WIDTH]) ? level_6_5_max_min_min_max_max_t : {level_6_5_max_min_min_max_max_t[0+:DATA_WIDTH],level_6_5_max_min_min_max_max_t[DATA_WIDTH+:DATA_WIDTH]};
    assign level_6_5_max_min_min_max_min = (level_6_5_max_min_min_max_min_t[0+:DATA_WIDTH]>level_6_5_max_min_min_max_min_t[DATA_WIDTH+:DATA_WIDTH]) ? level_6_5_max_min_min_max_min_t : {level_6_5_max_min_min_max_min_t[0+:DATA_WIDTH],level_6_5_max_min_min_max_min_t[DATA_WIDTH+:DATA_WIDTH]};
    assign level_6_5_max_min_min_min_max = (level_6_5_max_min_min_min_max_t[0+:DATA_WIDTH]>level_6_5_max_min_min_min_max_t[DATA_WIDTH+:DATA_WIDTH]) ? level_6_5_max_min_min_min_max_t : {level_6_5_max_min_min_min_max_t[0+:DATA_WIDTH],level_6_5_max_min_min_min_max_t[DATA_WIDTH+:DATA_WIDTH]};
    assign level_6_5_max_min_min_min_min = (level_6_5_max_min_min_min_min_t[0+:DATA_WIDTH]>level_6_5_max_min_min_min_min_t[DATA_WIDTH+:DATA_WIDTH]) ? level_6_5_max_min_min_min_min_t : {level_6_5_max_min_min_min_min_t[0+:DATA_WIDTH],level_6_5_max_min_min_min_min_t[DATA_WIDTH+:DATA_WIDTH]};
    assign level_6_5_min_max_max_max_max = (level_6_5_min_max_max_max_max_t[0+:DATA_WIDTH]>level_6_5_min_max_max_max_max_t[DATA_WIDTH+:DATA_WIDTH]) ? level_6_5_min_max_max_max_max_t : {level_6_5_min_max_max_max_max_t[0+:DATA_WIDTH],level_6_5_min_max_max_max_max_t[DATA_WIDTH+:DATA_WIDTH]};
    assign level_6_5_min_max_max_max_min = (level_6_5_min_max_max_max_min_t[0+:DATA_WIDTH]>level_6_5_min_max_max_max_min_t[DATA_WIDTH+:DATA_WIDTH]) ? level_6_5_min_max_max_max_min_t : {level_6_5_min_max_max_max_min_t[0+:DATA_WIDTH],level_6_5_min_max_max_max_min_t[DATA_WIDTH+:DATA_WIDTH]};
    assign level_6_5_min_max_max_min_max = (level_6_5_min_max_max_min_max_t[0+:DATA_WIDTH]>level_6_5_min_max_max_min_max_t[DATA_WIDTH+:DATA_WIDTH]) ? level_6_5_min_max_max_min_max_t : {level_6_5_min_max_max_min_max_t[0+:DATA_WIDTH],level_6_5_min_max_max_min_max_t[DATA_WIDTH+:DATA_WIDTH]};
    assign level_6_5_min_max_max_min_min = (level_6_5_min_max_max_min_min_t[0+:DATA_WIDTH]>level_6_5_min_max_max_min_min_t[DATA_WIDTH+:DATA_WIDTH]) ? level_6_5_min_max_max_min_min_t : {level_6_5_min_max_max_min_min_t[0+:DATA_WIDTH],level_6_5_min_max_max_min_min_t[DATA_WIDTH+:DATA_WIDTH]};
    assign level_6_5_min_max_min_max_max = (level_6_5_min_max_min_max_max_t[0+:DATA_WIDTH]>level_6_5_min_max_min_max_max_t[DATA_WIDTH+:DATA_WIDTH]) ? level_6_5_min_max_min_max_max_t : {level_6_5_min_max_min_max_max_t[0+:DATA_WIDTH],level_6_5_min_max_min_max_max_t[DATA_WIDTH+:DATA_WIDTH]};
    assign level_6_5_min_max_min_max_min = (level_6_5_min_max_min_max_min_t[0+:DATA_WIDTH]>level_6_5_min_max_min_max_min_t[DATA_WIDTH+:DATA_WIDTH]) ? level_6_5_min_max_min_max_min_t : {level_6_5_min_max_min_max_min_t[0+:DATA_WIDTH],level_6_5_min_max_min_max_min_t[DATA_WIDTH+:DATA_WIDTH]};
    assign level_6_5_min_max_min_min_max = (level_6_5_min_max_min_min_max_t[0+:DATA_WIDTH]>level_6_5_min_max_min_min_max_t[DATA_WIDTH+:DATA_WIDTH]) ? level_6_5_min_max_min_min_max_t : {level_6_5_min_max_min_min_max_t[0+:DATA_WIDTH],level_6_5_min_max_min_min_max_t[DATA_WIDTH+:DATA_WIDTH]};
    assign level_6_5_min_max_min_min_min = (level_6_5_min_max_min_min_min_t[0+:DATA_WIDTH]>level_6_5_min_max_min_min_min_t[DATA_WIDTH+:DATA_WIDTH]) ? level_6_5_min_max_min_min_min_t : {level_6_5_min_max_min_min_min_t[0+:DATA_WIDTH],level_6_5_min_max_min_min_min_t[DATA_WIDTH+:DATA_WIDTH]};
    assign level_6_5_min_min_max_max_max = (level_6_5_min_min_max_max_max_t[0+:DATA_WIDTH]>level_6_5_min_min_max_max_max_t[DATA_WIDTH+:DATA_WIDTH]) ? level_6_5_min_min_max_max_max_t : {level_6_5_min_min_max_max_max_t[0+:DATA_WIDTH],level_6_5_min_min_max_max_max_t[DATA_WIDTH+:DATA_WIDTH]};
    assign level_6_5_min_min_max_max_min = (level_6_5_min_min_max_max_min_t[0+:DATA_WIDTH]>level_6_5_min_min_max_max_min_t[DATA_WIDTH+:DATA_WIDTH]) ? level_6_5_min_min_max_max_min_t : {level_6_5_min_min_max_max_min_t[0+:DATA_WIDTH],level_6_5_min_min_max_max_min_t[DATA_WIDTH+:DATA_WIDTH]};
    assign level_6_5_min_min_max_min_max = (level_6_5_min_min_max_min_max_t[0+:DATA_WIDTH]>level_6_5_min_min_max_min_max_t[DATA_WIDTH+:DATA_WIDTH]) ? level_6_5_min_min_max_min_max_t : {level_6_5_min_min_max_min_max_t[0+:DATA_WIDTH],level_6_5_min_min_max_min_max_t[DATA_WIDTH+:DATA_WIDTH]};
    assign level_6_5_min_min_max_min_min = (level_6_5_min_min_max_min_min_t[0+:DATA_WIDTH]>level_6_5_min_min_max_min_min_t[DATA_WIDTH+:DATA_WIDTH]) ? level_6_5_min_min_max_min_min_t : {level_6_5_min_min_max_min_min_t[0+:DATA_WIDTH],level_6_5_min_min_max_min_min_t[DATA_WIDTH+:DATA_WIDTH]};
    assign level_6_5_min_min_min_max_max = (level_6_5_min_min_min_max_max_t[0+:DATA_WIDTH]>level_6_5_min_min_min_max_max_t[DATA_WIDTH+:DATA_WIDTH]) ? level_6_5_min_min_min_max_max_t : {level_6_5_min_min_min_max_max_t[0+:DATA_WIDTH],level_6_5_min_min_min_max_max_t[DATA_WIDTH+:DATA_WIDTH]};
    assign level_6_5_min_min_min_max_min = (level_6_5_min_min_min_max_min_t[0+:DATA_WIDTH]>level_6_5_min_min_min_max_min_t[DATA_WIDTH+:DATA_WIDTH]) ? level_6_5_min_min_min_max_min_t : {level_6_5_min_min_min_max_min_t[0+:DATA_WIDTH],level_6_5_min_min_min_max_min_t[DATA_WIDTH+:DATA_WIDTH]};
    assign level_6_5_min_min_min_min_max = (level_6_5_min_min_min_min_max_t[0+:DATA_WIDTH]>level_6_5_min_min_min_min_max_t[DATA_WIDTH+:DATA_WIDTH]) ? level_6_5_min_min_min_min_max_t : {level_6_5_min_min_min_min_max_t[0+:DATA_WIDTH],level_6_5_min_min_min_min_max_t[DATA_WIDTH+:DATA_WIDTH]};
    assign level_6_5_min_min_min_min_min = (level_6_5_min_min_min_min_min_t[0+:DATA_WIDTH]>level_6_5_min_min_min_min_min_t[DATA_WIDTH+:DATA_WIDTH]) ? level_6_5_min_min_min_min_min_t : {level_6_5_min_min_min_min_min_t[0+:DATA_WIDTH],level_6_5_min_min_min_min_min_t[DATA_WIDTH+:DATA_WIDTH]};

    assign level_6_w = {
                                 level_6_5_min_min_min_min_min,level_6_5_min_min_min_min_max,
                                 level_6_5_min_min_min_max_min,level_6_5_min_min_min_max_max,
                                 level_6_5_min_min_max_min_min,level_6_5_min_min_max_min_max,
                                 level_6_5_min_min_max_max_min,level_6_5_min_min_max_max_max,
                                 level_6_5_min_max_min_min_min,level_6_5_min_max_min_min_max,
                                 level_6_5_min_max_min_max_min,level_6_5_min_max_min_max_max,
                                 level_6_5_min_max_max_min_min,level_6_5_min_max_max_min_max,
                                 level_6_5_min_max_max_max_min,level_6_5_min_max_max_max_max,
                                 level_6_5_max_min_min_min_min,level_6_5_max_min_min_min_max,
                                 level_6_5_max_min_min_max_min,level_6_5_max_min_min_max_max,
                                 level_6_5_max_min_max_min_min,level_6_5_max_min_max_min_max,
                                 level_6_5_max_min_max_max_min,level_6_5_max_min_max_max_max,
                                 level_6_5_max_max_min_min_min,level_6_5_max_max_min_min_max,
                                 level_6_5_max_max_min_max_min,level_6_5_max_max_min_max_max,
                                 level_6_5_max_max_max_min_min,level_6_5_max_max_max_min_max,
                                 level_6_5_max_max_max_max_min,level_6_5_max_max_max_max_max};
    
    always@(posedge clk or negedge rst_n)
    begin
        if (!rst_n)
            level_6_r <= 'd0;
        else if(level_5_c_valid[1] && !ascend_5)
            level_6_r <= {level_6_r[0+:32*DATA_WIDTH],level_5_c_r};
        else
            level_6_r <= level_6_r;
    end
    
    always@(posedge clk or negedge rst_n)
    begin
        if(!rst_n)
            level_6_c_r <= 'd0;
        else
            level_6_c_r <= level_6_w;
    end
    
    always@(posedge clk or negedge rst_n)
    begin
        if(!rst_n)
            ascend_6 <= 1'b0;
        else if(level_5_c_valid[1] && !ascend_5)
            ascend_6 <= ~ascend_6;
    end
    
    always@(posedge clk or negedge rst_n)
    begin
        if (!rst_n)
            level_6_c_valid <= 'd0;
        else
            level_6_c_valid <= {level_6_c_valid[0],level_5_c_valid[1] & !ascend_5};
    end   
    
    //构建第7级双调
    reg [128*DATA_WIDTH-1:0] level_7_r;
    reg [128*DATA_WIDTH-1:0] level_7_c_r;
    reg ascend_7;
    reg [1:0] level_7_c_valid;
    wire [64*DATA_WIDTH-1:0] level_7_1_max;
    wire [64*DATA_WIDTH-1:0] level_7_1_min;
    
    wire [32*DATA_WIDTH-1:0] level_7_2_max_max_t;
    wire [32*DATA_WIDTH-1:0] level_7_2_max_min_t;
    wire [32*DATA_WIDTH-1:0] level_7_2_min_max_t;
    wire [32*DATA_WIDTH-1:0] level_7_2_min_min_t;
    
    wire [16*DATA_WIDTH-1:0] level_7_3_max_max_max_t;
    wire [16*DATA_WIDTH-1:0] level_7_3_max_max_min_t;
    wire [16*DATA_WIDTH-1:0] level_7_3_max_min_max_t;
    wire [16*DATA_WIDTH-1:0] level_7_3_max_min_min_t;
    wire [16*DATA_WIDTH-1:0] level_7_3_min_max_max_t;
    wire [16*DATA_WIDTH-1:0] level_7_3_min_max_min_t;
    wire [16*DATA_WIDTH-1:0] level_7_3_min_min_max_t;
    wire [16*DATA_WIDTH-1:0] level_7_3_min_min_min_t;
    
    wire [8*DATA_WIDTH-1:0] level_7_4_max_max_max_max_t;
    wire [8*DATA_WIDTH-1:0] level_7_4_max_max_max_min_t;
    wire [8*DATA_WIDTH-1:0] level_7_4_max_max_min_max_t;
    wire [8*DATA_WIDTH-1:0] level_7_4_max_max_min_min_t;
    wire [8*DATA_WIDTH-1:0] level_7_4_max_min_max_max_t;
    wire [8*DATA_WIDTH-1:0] level_7_4_max_min_max_min_t;
    wire [8*DATA_WIDTH-1:0] level_7_4_max_min_min_max_t;
    wire [8*DATA_WIDTH-1:0] level_7_4_max_min_min_min_t;
    wire [8*DATA_WIDTH-1:0] level_7_4_min_max_max_max_t;
    wire [8*DATA_WIDTH-1:0] level_7_4_min_max_max_min_t;
    wire [8*DATA_WIDTH-1:0] level_7_4_min_max_min_max_t;
    wire [8*DATA_WIDTH-1:0] level_7_4_min_max_min_min_t;
    wire [8*DATA_WIDTH-1:0] level_7_4_min_min_max_max_t;
    wire [8*DATA_WIDTH-1:0] level_7_4_min_min_max_min_t;
    wire [8*DATA_WIDTH-1:0] level_7_4_min_min_min_max_t;
    wire [8*DATA_WIDTH-1:0] level_7_4_min_min_min_min_t;
    
    wire [4*DATA_WIDTH-1:0] level_7_5_max_max_max_max_max_t;
    wire [4*DATA_WIDTH-1:0] level_7_5_max_max_max_max_min_t;   
    wire [4*DATA_WIDTH-1:0] level_7_5_max_max_max_min_max_t;
    wire [4*DATA_WIDTH-1:0] level_7_5_max_max_max_min_min_t;
    wire [4*DATA_WIDTH-1:0] level_7_5_max_max_min_max_max_t;
    wire [4*DATA_WIDTH-1:0] level_7_5_max_max_min_max_min_t;
    wire [4*DATA_WIDTH-1:0] level_7_5_max_max_min_min_max_t;
    wire [4*DATA_WIDTH-1:0] level_7_5_max_max_min_min_min_t;
    wire [4*DATA_WIDTH-1:0] level_7_5_max_min_max_max_max_t;
    wire [4*DATA_WIDTH-1:0] level_7_5_max_min_max_max_min_t;
    wire [4*DATA_WIDTH-1:0] level_7_5_max_min_max_min_max_t;
    wire [4*DATA_WIDTH-1:0] level_7_5_max_min_max_min_min_t;
    wire [4*DATA_WIDTH-1:0] level_7_5_max_min_min_max_max_t;
    wire [4*DATA_WIDTH-1:0] level_7_5_max_min_min_max_min_t;
    wire [4*DATA_WIDTH-1:0] level_7_5_max_min_min_min_max_t;
    wire [4*DATA_WIDTH-1:0] level_7_5_max_min_min_min_min_t;
    wire [4*DATA_WIDTH-1:0] level_7_5_min_max_max_max_max_t;
    wire [4*DATA_WIDTH-1:0] level_7_5_min_max_max_max_min_t;
    wire [4*DATA_WIDTH-1:0] level_7_5_min_max_max_min_max_t;
    wire [4*DATA_WIDTH-1:0] level_7_5_min_max_max_min_min_t;
    wire [4*DATA_WIDTH-1:0] level_7_5_min_max_min_max_max_t;
    wire [4*DATA_WIDTH-1:0] level_7_5_min_max_min_max_min_t;
    wire [4*DATA_WIDTH-1:0] level_7_5_min_max_min_min_max_t;
    wire [4*DATA_WIDTH-1:0] level_7_5_min_max_min_min_min_t;
    wire [4*DATA_WIDTH-1:0] level_7_5_min_min_max_max_max_t;
    wire [4*DATA_WIDTH-1:0] level_7_5_min_min_max_max_min_t;
    wire [4*DATA_WIDTH-1:0] level_7_5_min_min_max_min_max_t;
    wire [4*DATA_WIDTH-1:0] level_7_5_min_min_max_min_min_t;
    wire [4*DATA_WIDTH-1:0] level_7_5_min_min_min_max_max_t;
    wire [4*DATA_WIDTH-1:0] level_7_5_min_min_min_max_min_t;
    wire [4*DATA_WIDTH-1:0] level_7_5_min_min_min_min_max_t;
    wire [4*DATA_WIDTH-1:0] level_7_5_min_min_min_min_min_t;
    
    wire [2*DATA_WIDTH-1:0] level_7_6_max_max_max_max_max_max_t;
    wire [2*DATA_WIDTH-1:0] level_7_6_max_max_max_max_max_min_t;   
    wire [2*DATA_WIDTH-1:0] level_7_6_max_max_max_max_min_max_t;
    wire [2*DATA_WIDTH-1:0] level_7_6_max_max_max_max_min_min_t;
    wire [2*DATA_WIDTH-1:0] level_7_6_max_max_max_min_max_max_t;
    wire [2*DATA_WIDTH-1:0] level_7_6_max_max_max_min_max_min_t;
    wire [2*DATA_WIDTH-1:0] level_7_6_max_max_max_min_min_max_t;
    wire [2*DATA_WIDTH-1:0] level_7_6_max_max_max_min_min_min_t;
    wire [2*DATA_WIDTH-1:0] level_7_6_max_max_min_max_max_max_t;
    wire [2*DATA_WIDTH-1:0] level_7_6_max_max_min_max_max_min_t;
    wire [2*DATA_WIDTH-1:0] level_7_6_max_max_min_max_min_max_t;
    wire [2*DATA_WIDTH-1:0] level_7_6_max_max_min_max_min_min_t;
    wire [2*DATA_WIDTH-1:0] level_7_6_max_max_min_min_max_max_t;
    wire [2*DATA_WIDTH-1:0] level_7_6_max_max_min_min_max_min_t;
    wire [2*DATA_WIDTH-1:0] level_7_6_max_max_min_min_min_max_t;
    wire [2*DATA_WIDTH-1:0] level_7_6_max_max_min_min_min_min_t;
    wire [2*DATA_WIDTH-1:0] level_7_6_max_min_max_max_max_max_t;
    wire [2*DATA_WIDTH-1:0] level_7_6_max_min_max_max_max_min_t;
    wire [2*DATA_WIDTH-1:0] level_7_6_max_min_max_max_min_max_t;
    wire [2*DATA_WIDTH-1:0] level_7_6_max_min_max_max_min_min_t;
    wire [2*DATA_WIDTH-1:0] level_7_6_max_min_max_min_max_max_t;
    wire [2*DATA_WIDTH-1:0] level_7_6_max_min_max_min_max_min_t;
    wire [2*DATA_WIDTH-1:0] level_7_6_max_min_max_min_min_max_t;
    wire [2*DATA_WIDTH-1:0] level_7_6_max_min_max_min_min_min_t;
    wire [2*DATA_WIDTH-1:0] level_7_6_max_min_min_max_max_max_t;
    wire [2*DATA_WIDTH-1:0] level_7_6_max_min_min_max_max_min_t;
    wire [2*DATA_WIDTH-1:0] level_7_6_max_min_min_max_min_max_t;
    wire [2*DATA_WIDTH-1:0] level_7_6_max_min_min_max_min_min_t;
    wire [2*DATA_WIDTH-1:0] level_7_6_max_min_min_min_max_max_t;
    wire [2*DATA_WIDTH-1:0] level_7_6_max_min_min_min_max_min_t;
    wire [2*DATA_WIDTH-1:0] level_7_6_max_min_min_min_min_max_t;
    wire [2*DATA_WIDTH-1:0] level_7_6_max_min_min_min_min_min_t;     
    wire [2*DATA_WIDTH-1:0] level_7_6_min_max_max_max_max_max_t;
    wire [2*DATA_WIDTH-1:0] level_7_6_min_max_max_max_max_min_t;   
    wire [2*DATA_WIDTH-1:0] level_7_6_min_max_max_max_min_max_t;
    wire [2*DATA_WIDTH-1:0] level_7_6_min_max_max_max_min_min_t;
    wire [2*DATA_WIDTH-1:0] level_7_6_min_max_max_min_max_max_t;
    wire [2*DATA_WIDTH-1:0] level_7_6_min_max_max_min_max_min_t;
    wire [2*DATA_WIDTH-1:0] level_7_6_min_max_max_min_min_max_t;
    wire [2*DATA_WIDTH-1:0] level_7_6_min_max_max_min_min_min_t;
    wire [2*DATA_WIDTH-1:0] level_7_6_min_max_min_max_max_max_t;
    wire [2*DATA_WIDTH-1:0] level_7_6_min_max_min_max_max_min_t;
    wire [2*DATA_WIDTH-1:0] level_7_6_min_max_min_max_min_max_t;
    wire [2*DATA_WIDTH-1:0] level_7_6_min_max_min_max_min_min_t;
    wire [2*DATA_WIDTH-1:0] level_7_6_min_max_min_min_max_max_t;
    wire [2*DATA_WIDTH-1:0] level_7_6_min_max_min_min_max_min_t;
    wire [2*DATA_WIDTH-1:0] level_7_6_min_max_min_min_min_max_t;
    wire [2*DATA_WIDTH-1:0] level_7_6_min_max_min_min_min_min_t;
    wire [2*DATA_WIDTH-1:0] level_7_6_min_min_max_max_max_max_t;
    wire [2*DATA_WIDTH-1:0] level_7_6_min_min_max_max_max_min_t;
    wire [2*DATA_WIDTH-1:0] level_7_6_min_min_max_max_min_max_t;
    wire [2*DATA_WIDTH-1:0] level_7_6_min_min_max_max_min_min_t;
    wire [2*DATA_WIDTH-1:0] level_7_6_min_min_max_min_max_max_t;
    wire [2*DATA_WIDTH-1:0] level_7_6_min_min_max_min_max_min_t;
    wire [2*DATA_WIDTH-1:0] level_7_6_min_min_max_min_min_max_t;
    wire [2*DATA_WIDTH-1:0] level_7_6_min_min_max_min_min_min_t;
    wire [2*DATA_WIDTH-1:0] level_7_6_min_min_min_max_max_max_t;
    wire [2*DATA_WIDTH-1:0] level_7_6_min_min_min_max_max_min_t;
    wire [2*DATA_WIDTH-1:0] level_7_6_min_min_min_max_min_max_t;
    wire [2*DATA_WIDTH-1:0] level_7_6_min_min_min_max_min_min_t;
    wire [2*DATA_WIDTH-1:0] level_7_6_min_min_min_min_max_max_t;
    wire [2*DATA_WIDTH-1:0] level_7_6_min_min_min_min_max_min_t;
    wire [2*DATA_WIDTH-1:0] level_7_6_min_min_min_min_min_max_t;
    wire [2*DATA_WIDTH-1:0] level_7_6_min_min_min_min_min_min_t;

    wire [2*DATA_WIDTH-1:0] level_7_6_max_max_max_max_max_max;
    wire [2*DATA_WIDTH-1:0] level_7_6_max_max_max_max_max_min;   
    wire [2*DATA_WIDTH-1:0] level_7_6_max_max_max_max_min_max;
    wire [2*DATA_WIDTH-1:0] level_7_6_max_max_max_max_min_min;
    wire [2*DATA_WIDTH-1:0] level_7_6_max_max_max_min_max_max;
    wire [2*DATA_WIDTH-1:0] level_7_6_max_max_max_min_max_min;
    wire [2*DATA_WIDTH-1:0] level_7_6_max_max_max_min_min_max;
    wire [2*DATA_WIDTH-1:0] level_7_6_max_max_max_min_min_min;
    wire [2*DATA_WIDTH-1:0] level_7_6_max_max_min_max_max_max;
    wire [2*DATA_WIDTH-1:0] level_7_6_max_max_min_max_max_min;
    wire [2*DATA_WIDTH-1:0] level_7_6_max_max_min_max_min_max;
    wire [2*DATA_WIDTH-1:0] level_7_6_max_max_min_max_min_min;
    wire [2*DATA_WIDTH-1:0] level_7_6_max_max_min_min_max_max;
    wire [2*DATA_WIDTH-1:0] level_7_6_max_max_min_min_max_min;
    wire [2*DATA_WIDTH-1:0] level_7_6_max_max_min_min_min_max;
    wire [2*DATA_WIDTH-1:0] level_7_6_max_max_min_min_min_min;
    wire [2*DATA_WIDTH-1:0] level_7_6_max_min_max_max_max_max;
    wire [2*DATA_WIDTH-1:0] level_7_6_max_min_max_max_max_min;
    wire [2*DATA_WIDTH-1:0] level_7_6_max_min_max_max_min_max;
    wire [2*DATA_WIDTH-1:0] level_7_6_max_min_max_max_min_min;
    wire [2*DATA_WIDTH-1:0] level_7_6_max_min_max_min_max_max;
    wire [2*DATA_WIDTH-1:0] level_7_6_max_min_max_min_max_min;
    wire [2*DATA_WIDTH-1:0] level_7_6_max_min_max_min_min_max;
    wire [2*DATA_WIDTH-1:0] level_7_6_max_min_max_min_min_min;
    wire [2*DATA_WIDTH-1:0] level_7_6_max_min_min_max_max_max;
    wire [2*DATA_WIDTH-1:0] level_7_6_max_min_min_max_max_min;
    wire [2*DATA_WIDTH-1:0] level_7_6_max_min_min_max_min_max;
    wire [2*DATA_WIDTH-1:0] level_7_6_max_min_min_max_min_min;
    wire [2*DATA_WIDTH-1:0] level_7_6_max_min_min_min_max_max;
    wire [2*DATA_WIDTH-1:0] level_7_6_max_min_min_min_max_min;
    wire [2*DATA_WIDTH-1:0] level_7_6_max_min_min_min_min_max;
    wire [2*DATA_WIDTH-1:0] level_7_6_max_min_min_min_min_min;     
    wire [2*DATA_WIDTH-1:0] level_7_6_min_max_max_max_max_max;
    wire [2*DATA_WIDTH-1:0] level_7_6_min_max_max_max_max_min;   
    wire [2*DATA_WIDTH-1:0] level_7_6_min_max_max_max_min_max;
    wire [2*DATA_WIDTH-1:0] level_7_6_min_max_max_max_min_min;
    wire [2*DATA_WIDTH-1:0] level_7_6_min_max_max_min_max_max;
    wire [2*DATA_WIDTH-1:0] level_7_6_min_max_max_min_max_min;
    wire [2*DATA_WIDTH-1:0] level_7_6_min_max_max_min_min_max;
    wire [2*DATA_WIDTH-1:0] level_7_6_min_max_max_min_min_min;
    wire [2*DATA_WIDTH-1:0] level_7_6_min_max_min_max_max_max;
    wire [2*DATA_WIDTH-1:0] level_7_6_min_max_min_max_max_min;
    wire [2*DATA_WIDTH-1:0] level_7_6_min_max_min_max_min_max;
    wire [2*DATA_WIDTH-1:0] level_7_6_min_max_min_max_min_min;
    wire [2*DATA_WIDTH-1:0] level_7_6_min_max_min_min_max_max;
    wire [2*DATA_WIDTH-1:0] level_7_6_min_max_min_min_max_min;
    wire [2*DATA_WIDTH-1:0] level_7_6_min_max_min_min_min_max;
    wire [2*DATA_WIDTH-1:0] level_7_6_min_max_min_min_min_min;
    wire [2*DATA_WIDTH-1:0] level_7_6_min_min_max_max_max_max;
    wire [2*DATA_WIDTH-1:0] level_7_6_min_min_max_max_max_min;
    wire [2*DATA_WIDTH-1:0] level_7_6_min_min_max_max_min_max;
    wire [2*DATA_WIDTH-1:0] level_7_6_min_min_max_max_min_min;
    wire [2*DATA_WIDTH-1:0] level_7_6_min_min_max_min_max_max;
    wire [2*DATA_WIDTH-1:0] level_7_6_min_min_max_min_max_min;
    wire [2*DATA_WIDTH-1:0] level_7_6_min_min_max_min_min_max;
    wire [2*DATA_WIDTH-1:0] level_7_6_min_min_max_min_min_min;
    wire [2*DATA_WIDTH-1:0] level_7_6_min_min_min_max_max_max;
    wire [2*DATA_WIDTH-1:0] level_7_6_min_min_min_max_max_min;
    wire [2*DATA_WIDTH-1:0] level_7_6_min_min_min_max_min_max;
    wire [2*DATA_WIDTH-1:0] level_7_6_min_min_min_max_min_min;
    wire [2*DATA_WIDTH-1:0] level_7_6_min_min_min_min_max_max;
    wire [2*DATA_WIDTH-1:0] level_7_6_min_min_min_min_max_min;
    wire [2*DATA_WIDTH-1:0] level_7_6_min_min_min_min_min_max;
    wire [2*DATA_WIDTH-1:0] level_7_6_min_min_min_min_min_min;

    wire [128*DATA_WIDTH-1:0] level_7_w;
    
    generate
    for (i=0;i<64;i=i+1)
        begin:gen_7_1
            assign level_7_1_max[i*DATA_WIDTH+:DATA_WIDTH] = (level_7_r[(128-i)*DATA_WIDTH-1-:DATA_WIDTH] >level_7_r[i*DATA_WIDTH+:DATA_WIDTH]) ? level_7_r[(128-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_7_r[i*DATA_WIDTH+:DATA_WIDTH];   
            assign level_7_1_min[i*DATA_WIDTH+:DATA_WIDTH] = (level_7_r[(128-i)*DATA_WIDTH-1-:DATA_WIDTH] >level_7_r[i*DATA_WIDTH+:DATA_WIDTH]) ?  level_7_r[i*DATA_WIDTH+:DATA_WIDTH] : level_7_r[(128-i)*DATA_WIDTH-1-:DATA_WIDTH];
        end
    endgenerate
    
    generate
    for (i=0;i<32;i=i+1)
        begin:gen_7_2
            assign level_7_2_max_max_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_7_1_max[(64-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_7_1_max[(32-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_7_1_max[(64-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_7_1_max[(32-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_7_2_max_min_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_7_1_max[(64-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_7_1_max[(32-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_7_1_max[(32-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_7_1_max[(64-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_7_2_min_max_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_7_1_min[(64-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_7_1_min[(32-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_7_1_min[(64-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_7_1_min[(32-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_7_2_min_min_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_7_1_min[(64-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_7_1_min[(32-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_7_1_min[(32-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_7_1_min[(64-i)*DATA_WIDTH-1-:DATA_WIDTH];           
        end
    endgenerate
    
    generate
    for (i=0;i<16;i=i+1)
        begin:gen_7_3
            assign level_7_3_max_max_max_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_7_2_max_max_t[(32-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_7_2_max_max_t[(16-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_7_2_max_max_t[(32-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_7_2_max_max_t[(16-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_7_3_max_max_min_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_7_2_max_max_t[(32-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_7_2_max_max_t[(16-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_7_2_max_max_t[(16-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_7_2_max_max_t[(32-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_7_3_max_min_max_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_7_2_max_min_t[(32-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_7_2_max_min_t[(16-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_7_2_max_min_t[(32-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_7_2_max_min_t[(16-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_7_3_max_min_min_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_7_2_max_min_t[(32-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_7_2_max_min_t[(16-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_7_2_max_min_t[(16-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_7_2_max_min_t[(32-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_7_3_min_max_max_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_7_2_min_max_t[(32-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_7_2_min_max_t[(16-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_7_2_min_max_t[(32-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_7_2_min_max_t[(16-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_7_3_min_max_min_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_7_2_min_max_t[(32-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_7_2_min_max_t[(16-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_7_2_min_max_t[(16-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_7_2_min_max_t[(32-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_7_3_min_min_max_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_7_2_min_min_t[(32-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_7_2_min_min_t[(16-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_7_2_min_min_t[(32-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_7_2_min_min_t[(16-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_7_3_min_min_min_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_7_2_min_min_t[(32-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_7_2_min_min_t[(16-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_7_2_min_min_t[(16-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_7_2_min_min_t[(32-i)*DATA_WIDTH-1-:DATA_WIDTH];
        end
    endgenerate
    
    generate
    for (i=0;i<8;i=i+1)
        begin:gen_7_4
            assign level_7_4_max_max_max_max_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_7_3_max_max_max_t[(16-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_7_3_max_max_max_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_7_3_max_max_max_t[(16-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_7_3_max_max_max_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_7_4_max_max_max_min_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_7_3_max_max_max_t[(16-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_7_3_max_max_max_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_7_3_max_max_max_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_7_3_max_max_max_t[(16-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_7_4_max_max_min_max_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_7_3_max_max_min_t[(16-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_7_3_max_max_min_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_7_3_max_max_min_t[(16-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_7_3_max_max_min_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_7_4_max_max_min_min_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_7_3_max_max_min_t[(16-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_7_3_max_max_min_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_7_3_max_max_min_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_7_3_max_max_min_t[(16-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_7_4_max_min_max_max_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_7_3_max_min_max_t[(16-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_7_3_max_min_max_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_7_3_max_min_max_t[(16-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_7_3_max_min_max_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_7_4_max_min_max_min_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_7_3_max_min_max_t[(16-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_7_3_max_min_max_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_7_3_max_min_max_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_7_3_max_min_max_t[(16-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_7_4_max_min_min_max_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_7_3_max_min_min_t[(16-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_7_3_max_min_min_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_7_3_max_min_min_t[(16-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_7_3_max_min_min_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_7_4_max_min_min_min_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_7_3_max_min_min_t[(16-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_7_3_max_min_min_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_7_3_max_min_min_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_7_3_max_min_min_t[(16-i)*DATA_WIDTH-1-:DATA_WIDTH];          
            assign level_7_4_min_max_max_max_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_7_3_min_max_max_t[(16-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_7_3_min_max_max_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_7_3_min_max_max_t[(16-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_7_3_min_max_max_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_7_4_min_max_max_min_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_7_3_min_max_max_t[(16-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_7_3_min_max_max_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_7_3_min_max_max_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_7_3_min_max_max_t[(16-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_7_4_min_max_min_max_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_7_3_min_max_min_t[(16-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_7_3_min_max_min_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_7_3_min_max_min_t[(16-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_7_3_min_max_min_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_7_4_min_max_min_min_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_7_3_min_max_min_t[(16-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_7_3_min_max_min_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_7_3_min_max_min_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_7_3_min_max_min_t[(16-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_7_4_min_min_max_max_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_7_3_min_min_max_t[(16-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_7_3_min_min_max_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_7_3_min_min_max_t[(16-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_7_3_min_min_max_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_7_4_min_min_max_min_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_7_3_min_min_max_t[(16-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_7_3_min_min_max_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_7_3_min_min_max_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_7_3_min_min_max_t[(16-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_7_4_min_min_min_max_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_7_3_min_min_min_t[(16-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_7_3_min_min_min_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_7_3_min_min_min_t[(16-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_7_3_min_min_min_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_7_4_min_min_min_min_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_7_3_min_min_min_t[(16-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_7_3_min_min_min_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_7_3_min_min_min_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_7_3_min_min_min_t[(16-i)*DATA_WIDTH-1-:DATA_WIDTH];
        end
    endgenerate    
    
    generate
    for (i=0;i<4;i=i+1)
        begin:gen_7_5
            assign level_7_5_max_max_max_max_max_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_7_4_max_max_max_max_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_7_4_max_max_max_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_7_4_max_max_max_max_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_7_4_max_max_max_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_7_5_max_max_max_max_min_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_7_4_max_max_max_max_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_7_4_max_max_max_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_7_4_max_max_max_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_7_4_max_max_max_max_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_7_5_max_max_max_min_max_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_7_4_max_max_max_min_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_7_4_max_max_max_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_7_4_max_max_max_min_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_7_4_max_max_max_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_7_5_max_max_max_min_min_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_7_4_max_max_max_min_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_7_4_max_max_max_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_7_4_max_max_max_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_7_4_max_max_max_min_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_7_5_max_max_min_max_max_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_7_4_max_max_min_max_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_7_4_max_max_min_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_7_4_max_max_min_max_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_7_4_max_max_min_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_7_5_max_max_min_max_min_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_7_4_max_max_min_max_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_7_4_max_max_min_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_7_4_max_max_min_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_7_4_max_max_min_max_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_7_5_max_max_min_min_max_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_7_4_max_max_min_min_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_7_4_max_max_min_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_7_4_max_max_min_min_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_7_4_max_max_min_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_7_5_max_max_min_min_min_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_7_4_max_max_min_min_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_7_4_max_max_min_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_7_4_max_max_min_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_7_4_max_max_min_min_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH];          
            assign level_7_5_max_min_max_max_max_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_7_4_max_min_max_max_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_7_4_max_min_max_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_7_4_max_min_max_max_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_7_4_max_min_max_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_7_5_max_min_max_max_min_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_7_4_max_min_max_max_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_7_4_max_min_max_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_7_4_max_min_max_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_7_4_max_min_max_max_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_7_5_max_min_max_min_max_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_7_4_max_min_max_min_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_7_4_max_min_max_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_7_4_max_min_max_min_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_7_4_max_min_max_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_7_5_max_min_max_min_min_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_7_4_max_min_max_min_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_7_4_max_min_max_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_7_4_max_min_max_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_7_4_max_min_max_min_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_7_5_max_min_min_max_max_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_7_4_max_min_min_max_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_7_4_max_min_min_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_7_4_max_min_min_max_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_7_4_max_min_min_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_7_5_max_min_min_max_min_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_7_4_max_min_min_max_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_7_4_max_min_min_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_7_4_max_min_min_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_7_4_max_min_min_max_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_7_5_max_min_min_min_max_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_7_4_max_min_min_min_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_7_4_max_min_min_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_7_4_max_min_min_min_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_7_4_max_min_min_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_7_5_max_min_min_min_min_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_7_4_max_min_min_min_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_7_4_max_min_min_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_7_4_max_min_min_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_7_4_max_min_min_min_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_7_5_min_max_max_max_max_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_7_4_min_max_max_max_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_7_4_min_max_max_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_7_4_min_max_max_max_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_7_4_min_max_max_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_7_5_min_max_max_max_min_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_7_4_min_max_max_max_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_7_4_min_max_max_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_7_4_min_max_max_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_7_4_min_max_max_max_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_7_5_min_max_max_min_max_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_7_4_min_max_max_min_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_7_4_min_max_max_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_7_4_min_max_max_min_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_7_4_min_max_max_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_7_5_min_max_max_min_min_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_7_4_min_max_max_min_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_7_4_min_max_max_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_7_4_min_max_max_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_7_4_min_max_max_min_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_7_5_min_max_min_max_max_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_7_4_min_max_min_max_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_7_4_min_max_min_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_7_4_min_max_min_max_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_7_4_min_max_min_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_7_5_min_max_min_max_min_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_7_4_min_max_min_max_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_7_4_min_max_min_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_7_4_min_max_min_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_7_4_min_max_min_max_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_7_5_min_max_min_min_max_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_7_4_min_max_min_min_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_7_4_min_max_min_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_7_4_min_max_min_min_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_7_4_min_max_min_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_7_5_min_max_min_min_min_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_7_4_min_max_min_min_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_7_4_min_max_min_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_7_4_min_max_min_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_7_4_min_max_min_min_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH];          
            assign level_7_5_min_min_max_max_max_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_7_4_min_min_max_max_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_7_4_min_min_max_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_7_4_min_min_max_max_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_7_4_min_min_max_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_7_5_min_min_max_max_min_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_7_4_min_min_max_max_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_7_4_min_min_max_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_7_4_min_min_max_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_7_4_min_min_max_max_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_7_5_min_min_max_min_max_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_7_4_min_min_max_min_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_7_4_min_min_max_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_7_4_min_min_max_min_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_7_4_min_min_max_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_7_5_min_min_max_min_min_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_7_4_min_min_max_min_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_7_4_min_min_max_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_7_4_min_min_max_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_7_4_min_min_max_min_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_7_5_min_min_min_max_max_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_7_4_min_min_min_max_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_7_4_min_min_min_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_7_4_min_min_min_max_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_7_4_min_min_min_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_7_5_min_min_min_max_min_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_7_4_min_min_min_max_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_7_4_min_min_min_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_7_4_min_min_min_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_7_4_min_min_min_max_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_7_5_min_min_min_min_max_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_7_4_min_min_min_min_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_7_4_min_min_min_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_7_4_min_min_min_min_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_7_4_min_min_min_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_7_5_min_min_min_min_min_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_7_4_min_min_min_min_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_7_4_min_min_min_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_7_4_min_min_min_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_7_4_min_min_min_min_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH];
        end
    endgenerate
    
    generate
    for (i=0;i<2;i=i+1)
        begin:gen_7_6
            assign level_7_6_max_max_max_max_max_max_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_7_5_max_max_max_max_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_7_5_max_max_max_max_max_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_7_5_max_max_max_max_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_7_5_max_max_max_max_max_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_7_6_max_max_max_max_max_min_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_7_5_max_max_max_max_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_7_5_max_max_max_max_max_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_7_5_max_max_max_max_max_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_7_5_max_max_max_max_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_7_6_max_max_max_max_min_max_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_7_5_max_max_max_max_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_7_5_max_max_max_max_min_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_7_5_max_max_max_max_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_7_5_max_max_max_max_min_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_7_6_max_max_max_max_min_min_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_7_5_max_max_max_max_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_7_5_max_max_max_max_min_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_7_5_max_max_max_max_min_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_7_5_max_max_max_max_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_7_6_max_max_max_min_max_max_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_7_5_max_max_max_min_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_7_5_max_max_max_min_max_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_7_5_max_max_max_min_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_7_5_max_max_max_min_max_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_7_6_max_max_max_min_max_min_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_7_5_max_max_max_min_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_7_5_max_max_max_min_max_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_7_5_max_max_max_min_max_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_7_5_max_max_max_min_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_7_6_max_max_max_min_min_max_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_7_5_max_max_max_min_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_7_5_max_max_max_min_min_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_7_5_max_max_max_min_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_7_5_max_max_max_min_min_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_7_6_max_max_max_min_min_min_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_7_5_max_max_max_min_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_7_5_max_max_max_min_min_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_7_5_max_max_max_min_min_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_7_5_max_max_max_min_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH];          
            assign level_7_6_max_max_min_max_max_max_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_7_5_max_max_min_max_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_7_5_max_max_min_max_max_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_7_5_max_max_min_max_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_7_5_max_max_min_max_max_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_7_6_max_max_min_max_max_min_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_7_5_max_max_min_max_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_7_5_max_max_min_max_max_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_7_5_max_max_min_max_max_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_7_5_max_max_min_max_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_7_6_max_max_min_max_min_max_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_7_5_max_max_min_max_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_7_5_max_max_min_max_min_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_7_5_max_max_min_max_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_7_5_max_max_min_max_min_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_7_6_max_max_min_max_min_min_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_7_5_max_max_min_max_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_7_5_max_max_min_max_min_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_7_5_max_max_min_max_min_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_7_5_max_max_min_max_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_7_6_max_max_min_min_max_max_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_7_5_max_max_min_min_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_7_5_max_max_min_min_max_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_7_5_max_max_min_min_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_7_5_max_max_min_min_max_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_7_6_max_max_min_min_max_min_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_7_5_max_max_min_min_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_7_5_max_max_min_min_max_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_7_5_max_max_min_min_max_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_7_5_max_max_min_min_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_7_6_max_max_min_min_min_max_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_7_5_max_max_min_min_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_7_5_max_max_min_min_min_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_7_5_max_max_min_min_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_7_5_max_max_min_min_min_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_7_6_max_max_min_min_min_min_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_7_5_max_max_min_min_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_7_5_max_max_min_min_min_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_7_5_max_max_min_min_min_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_7_5_max_max_min_min_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_7_6_max_min_max_max_max_max_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_7_5_max_min_max_max_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_7_5_max_min_max_max_max_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_7_5_max_min_max_max_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_7_5_max_min_max_max_max_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_7_6_max_min_max_max_max_min_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_7_5_max_min_max_max_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_7_5_max_min_max_max_max_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_7_5_max_min_max_max_max_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_7_5_max_min_max_max_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_7_6_max_min_max_max_min_max_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_7_5_max_min_max_max_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_7_5_max_min_max_max_min_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_7_5_max_min_max_max_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_7_5_max_min_max_max_min_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_7_6_max_min_max_max_min_min_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_7_5_max_min_max_max_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_7_5_max_min_max_max_min_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_7_5_max_min_max_max_min_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_7_5_max_min_max_max_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_7_6_max_min_max_min_max_max_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_7_5_max_min_max_min_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_7_5_max_min_max_min_max_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_7_5_max_min_max_min_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_7_5_max_min_max_min_max_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_7_6_max_min_max_min_max_min_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_7_5_max_min_max_min_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_7_5_max_min_max_min_max_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_7_5_max_min_max_min_max_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_7_5_max_min_max_min_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_7_6_max_min_max_min_min_max_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_7_5_max_min_max_min_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_7_5_max_min_max_min_min_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_7_5_max_min_max_min_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_7_5_max_min_max_min_min_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_7_6_max_min_max_min_min_min_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_7_5_max_min_max_min_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_7_5_max_min_max_min_min_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_7_5_max_min_max_min_min_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_7_5_max_min_max_min_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH];          
            assign level_7_6_max_min_min_max_max_max_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_7_5_max_min_min_max_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_7_5_max_min_min_max_max_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_7_5_max_min_min_max_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_7_5_max_min_min_max_max_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_7_6_max_min_min_max_max_min_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_7_5_max_min_min_max_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_7_5_max_min_min_max_max_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_7_5_max_min_min_max_max_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_7_5_max_min_min_max_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_7_6_max_min_min_max_min_max_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_7_5_max_min_min_max_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_7_5_max_min_min_max_min_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_7_5_max_min_min_max_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_7_5_max_min_min_max_min_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_7_6_max_min_min_max_min_min_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_7_5_max_min_min_max_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_7_5_max_min_min_max_min_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_7_5_max_min_min_max_min_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_7_5_max_min_min_max_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_7_6_max_min_min_min_max_max_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_7_5_max_min_min_min_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_7_5_max_min_min_min_max_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_7_5_max_min_min_min_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_7_5_max_min_min_min_max_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_7_6_max_min_min_min_max_min_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_7_5_max_min_min_min_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_7_5_max_min_min_min_max_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_7_5_max_min_min_min_max_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_7_5_max_min_min_min_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_7_6_max_min_min_min_min_max_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_7_5_max_min_min_min_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_7_5_max_min_min_min_min_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_7_5_max_min_min_min_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_7_5_max_min_min_min_min_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_7_6_max_min_min_min_min_min_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_7_5_max_min_min_min_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_7_5_max_min_min_min_min_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_7_5_max_min_min_min_min_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_7_5_max_min_min_min_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_7_6_min_max_max_max_max_max_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_7_5_min_max_max_max_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_7_5_min_max_max_max_max_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_7_5_min_max_max_max_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_7_5_min_max_max_max_max_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_7_6_min_max_max_max_max_min_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_7_5_min_max_max_max_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_7_5_min_max_max_max_max_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_7_5_min_max_max_max_max_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_7_5_min_max_max_max_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_7_6_min_max_max_max_min_max_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_7_5_min_max_max_max_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_7_5_min_max_max_max_min_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_7_5_min_max_max_max_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_7_5_min_max_max_max_min_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_7_6_min_max_max_max_min_min_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_7_5_min_max_max_max_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_7_5_min_max_max_max_min_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_7_5_min_max_max_max_min_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_7_5_min_max_max_max_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_7_6_min_max_max_min_max_max_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_7_5_min_max_max_min_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_7_5_min_max_max_min_max_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_7_5_min_max_max_min_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_7_5_min_max_max_min_max_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_7_6_min_max_max_min_max_min_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_7_5_min_max_max_min_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_7_5_min_max_max_min_max_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_7_5_min_max_max_min_max_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_7_5_min_max_max_min_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_7_6_min_max_max_min_min_max_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_7_5_min_max_max_min_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_7_5_min_max_max_min_min_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_7_5_min_max_max_min_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_7_5_min_max_max_min_min_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_7_6_min_max_max_min_min_min_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_7_5_min_max_max_min_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_7_5_min_max_max_min_min_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_7_5_min_max_max_min_min_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_7_5_min_max_max_min_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH];          
            assign level_7_6_min_max_min_max_max_max_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_7_5_min_max_min_max_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_7_5_min_max_min_max_max_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_7_5_min_max_min_max_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_7_5_min_max_min_max_max_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_7_6_min_max_min_max_max_min_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_7_5_min_max_min_max_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_7_5_min_max_min_max_max_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_7_5_min_max_min_max_max_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_7_5_min_max_min_max_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_7_6_min_max_min_max_min_max_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_7_5_min_max_min_max_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_7_5_min_max_min_max_min_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_7_5_min_max_min_max_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_7_5_min_max_min_max_min_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_7_6_min_max_min_max_min_min_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_7_5_min_max_min_max_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_7_5_min_max_min_max_min_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_7_5_min_max_min_max_min_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_7_5_min_max_min_max_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_7_6_min_max_min_min_max_max_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_7_5_min_max_min_min_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_7_5_min_max_min_min_max_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_7_5_min_max_min_min_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_7_5_min_max_min_min_max_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_7_6_min_max_min_min_max_min_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_7_5_min_max_min_min_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_7_5_min_max_min_min_max_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_7_5_min_max_min_min_max_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_7_5_min_max_min_min_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_7_6_min_max_min_min_min_max_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_7_5_min_max_min_min_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_7_5_min_max_min_min_min_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_7_5_min_max_min_min_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_7_5_min_max_min_min_min_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_7_6_min_max_min_min_min_min_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_7_5_min_max_min_min_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_7_5_min_max_min_min_min_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_7_5_min_max_min_min_min_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_7_5_min_max_min_min_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_7_6_min_min_max_max_max_max_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_7_5_min_min_max_max_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_7_5_min_min_max_max_max_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_7_5_min_min_max_max_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_7_5_min_min_max_max_max_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_7_6_min_min_max_max_max_min_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_7_5_min_min_max_max_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_7_5_min_min_max_max_max_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_7_5_min_min_max_max_max_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_7_5_min_min_max_max_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_7_6_min_min_max_max_min_max_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_7_5_min_min_max_max_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_7_5_min_min_max_max_min_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_7_5_min_min_max_max_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_7_5_min_min_max_max_min_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_7_6_min_min_max_max_min_min_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_7_5_min_min_max_max_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_7_5_min_min_max_max_min_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_7_5_min_min_max_max_min_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_7_5_min_min_max_max_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_7_6_min_min_max_min_max_max_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_7_5_min_min_max_min_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_7_5_min_min_max_min_max_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_7_5_min_min_max_min_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_7_5_min_min_max_min_max_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_7_6_min_min_max_min_max_min_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_7_5_min_min_max_min_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_7_5_min_min_max_min_max_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_7_5_min_min_max_min_max_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_7_5_min_min_max_min_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_7_6_min_min_max_min_min_max_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_7_5_min_min_max_min_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_7_5_min_min_max_min_min_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_7_5_min_min_max_min_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_7_5_min_min_max_min_min_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_7_6_min_min_max_min_min_min_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_7_5_min_min_max_min_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_7_5_min_min_max_min_min_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_7_5_min_min_max_min_min_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_7_5_min_min_max_min_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH];          
            assign level_7_6_min_min_min_max_max_max_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_7_5_min_min_min_max_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_7_5_min_min_min_max_max_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_7_5_min_min_min_max_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_7_5_min_min_min_max_max_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_7_6_min_min_min_max_max_min_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_7_5_min_min_min_max_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_7_5_min_min_min_max_max_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_7_5_min_min_min_max_max_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_7_5_min_min_min_max_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_7_6_min_min_min_max_min_max_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_7_5_min_min_min_max_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_7_5_min_min_min_max_min_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_7_5_min_min_min_max_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_7_5_min_min_min_max_min_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_7_6_min_min_min_max_min_min_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_7_5_min_min_min_max_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_7_5_min_min_min_max_min_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_7_5_min_min_min_max_min_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_7_5_min_min_min_max_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_7_6_min_min_min_min_max_max_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_7_5_min_min_min_min_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_7_5_min_min_min_min_max_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_7_5_min_min_min_min_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_7_5_min_min_min_min_max_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_7_6_min_min_min_min_max_min_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_7_5_min_min_min_min_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_7_5_min_min_min_min_max_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_7_5_min_min_min_min_max_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_7_5_min_min_min_min_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_7_6_min_min_min_min_min_max_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_7_5_min_min_min_min_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_7_5_min_min_min_min_min_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_7_5_min_min_min_min_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_7_5_min_min_min_min_min_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_7_6_min_min_min_min_min_min_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_7_5_min_min_min_min_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_7_5_min_min_min_min_min_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_7_5_min_min_min_min_min_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_7_5_min_min_min_min_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH];
        end
    endgenerate  
    
    assign level_7_6_max_max_max_max_max_max = (level_7_6_max_max_max_max_max_max_t[0+:DATA_WIDTH]>level_7_6_max_max_max_max_max_max_t[DATA_WIDTH+:DATA_WIDTH]) ? level_7_6_max_max_max_max_max_max_t : {level_7_6_max_max_max_max_max_max_t[0+:DATA_WIDTH],level_7_6_max_max_max_max_max_max_t[DATA_WIDTH+:DATA_WIDTH]};
    assign level_7_6_max_max_max_max_max_min = (level_7_6_max_max_max_max_max_min_t[0+:DATA_WIDTH]>level_7_6_max_max_max_max_max_min_t[DATA_WIDTH+:DATA_WIDTH]) ? level_7_6_max_max_max_max_max_min_t : {level_7_6_max_max_max_max_max_min_t[0+:DATA_WIDTH],level_7_6_max_max_max_max_max_min_t[DATA_WIDTH+:DATA_WIDTH]};
    assign level_7_6_max_max_max_max_min_max = (level_7_6_max_max_max_max_min_max_t[0+:DATA_WIDTH]>level_7_6_max_max_max_max_min_max_t[DATA_WIDTH+:DATA_WIDTH]) ? level_7_6_max_max_max_max_min_max_t : {level_7_6_max_max_max_max_min_max_t[0+:DATA_WIDTH],level_7_6_max_max_max_max_min_max_t[DATA_WIDTH+:DATA_WIDTH]};
    assign level_7_6_max_max_max_max_min_min = (level_7_6_max_max_max_max_min_min_t[0+:DATA_WIDTH]>level_7_6_max_max_max_max_min_min_t[DATA_WIDTH+:DATA_WIDTH]) ? level_7_6_max_max_max_max_min_min_t : {level_7_6_max_max_max_max_min_min_t[0+:DATA_WIDTH],level_7_6_max_max_max_max_min_min_t[DATA_WIDTH+:DATA_WIDTH]};
    assign level_7_6_max_max_max_min_max_max = (level_7_6_max_max_max_min_max_max_t[0+:DATA_WIDTH]>level_7_6_max_max_max_min_max_max_t[DATA_WIDTH+:DATA_WIDTH]) ? level_7_6_max_max_max_min_max_max_t : {level_7_6_max_max_max_min_max_max_t[0+:DATA_WIDTH],level_7_6_max_max_max_min_max_max_t[DATA_WIDTH+:DATA_WIDTH]};
    assign level_7_6_max_max_max_min_max_min = (level_7_6_max_max_max_min_max_min_t[0+:DATA_WIDTH]>level_7_6_max_max_max_min_max_min_t[DATA_WIDTH+:DATA_WIDTH]) ? level_7_6_max_max_max_min_max_min_t : {level_7_6_max_max_max_min_max_min_t[0+:DATA_WIDTH],level_7_6_max_max_max_min_max_min_t[DATA_WIDTH+:DATA_WIDTH]};
    assign level_7_6_max_max_max_min_min_max = (level_7_6_max_max_max_min_min_max_t[0+:DATA_WIDTH]>level_7_6_max_max_max_min_min_max_t[DATA_WIDTH+:DATA_WIDTH]) ? level_7_6_max_max_max_min_min_max_t : {level_7_6_max_max_max_min_min_max_t[0+:DATA_WIDTH],level_7_6_max_max_max_min_min_max_t[DATA_WIDTH+:DATA_WIDTH]};
    assign level_7_6_max_max_max_min_min_min = (level_7_6_max_max_max_min_min_min_t[0+:DATA_WIDTH]>level_7_6_max_max_max_min_min_min_t[DATA_WIDTH+:DATA_WIDTH]) ? level_7_6_max_max_max_min_min_min_t : {level_7_6_max_max_max_min_min_min_t[0+:DATA_WIDTH],level_7_6_max_max_max_min_min_min_t[DATA_WIDTH+:DATA_WIDTH]};
    assign level_7_6_max_max_min_max_max_max = (level_7_6_max_max_min_max_max_max_t[0+:DATA_WIDTH]>level_7_6_max_max_min_max_max_max_t[DATA_WIDTH+:DATA_WIDTH]) ? level_7_6_max_max_min_max_max_max_t : {level_7_6_max_max_min_max_max_max_t[0+:DATA_WIDTH],level_7_6_max_max_min_max_max_max_t[DATA_WIDTH+:DATA_WIDTH]};
    assign level_7_6_max_max_min_max_max_min = (level_7_6_max_max_min_max_max_min_t[0+:DATA_WIDTH]>level_7_6_max_max_min_max_max_min_t[DATA_WIDTH+:DATA_WIDTH]) ? level_7_6_max_max_min_max_max_min_t : {level_7_6_max_max_min_max_max_min_t[0+:DATA_WIDTH],level_7_6_max_max_min_max_max_min_t[DATA_WIDTH+:DATA_WIDTH]};
    assign level_7_6_max_max_min_max_min_max = (level_7_6_max_max_min_max_min_max_t[0+:DATA_WIDTH]>level_7_6_max_max_min_max_min_max_t[DATA_WIDTH+:DATA_WIDTH]) ? level_7_6_max_max_min_max_min_max_t : {level_7_6_max_max_min_max_min_max_t[0+:DATA_WIDTH],level_7_6_max_max_min_max_min_max_t[DATA_WIDTH+:DATA_WIDTH]};
    assign level_7_6_max_max_min_max_min_min = (level_7_6_max_max_min_max_min_min_t[0+:DATA_WIDTH]>level_7_6_max_max_min_max_min_min_t[DATA_WIDTH+:DATA_WIDTH]) ? level_7_6_max_max_min_max_min_min_t : {level_7_6_max_max_min_max_min_min_t[0+:DATA_WIDTH],level_7_6_max_max_min_max_min_min_t[DATA_WIDTH+:DATA_WIDTH]};
    assign level_7_6_max_max_min_min_max_max = (level_7_6_max_max_min_min_max_max_t[0+:DATA_WIDTH]>level_7_6_max_max_min_min_max_max_t[DATA_WIDTH+:DATA_WIDTH]) ? level_7_6_max_max_min_min_max_max_t : {level_7_6_max_max_min_min_max_max_t[0+:DATA_WIDTH],level_7_6_max_max_min_min_max_max_t[DATA_WIDTH+:DATA_WIDTH]};
    assign level_7_6_max_max_min_min_max_min = (level_7_6_max_max_min_min_max_min_t[0+:DATA_WIDTH]>level_7_6_max_max_min_min_max_min_t[DATA_WIDTH+:DATA_WIDTH]) ? level_7_6_max_max_min_min_max_min_t : {level_7_6_max_max_min_min_max_min_t[0+:DATA_WIDTH],level_7_6_max_max_min_min_max_min_t[DATA_WIDTH+:DATA_WIDTH]};
    assign level_7_6_max_max_min_min_min_max = (level_7_6_max_max_min_min_min_max_t[0+:DATA_WIDTH]>level_7_6_max_max_min_min_min_max_t[DATA_WIDTH+:DATA_WIDTH]) ? level_7_6_max_max_min_min_min_max_t : {level_7_6_max_max_min_min_min_max_t[0+:DATA_WIDTH],level_7_6_max_max_min_min_min_max_t[DATA_WIDTH+:DATA_WIDTH]};
    assign level_7_6_max_max_min_min_min_min = (level_7_6_max_max_min_min_min_min_t[0+:DATA_WIDTH]>level_7_6_max_max_min_min_min_min_t[DATA_WIDTH+:DATA_WIDTH]) ? level_7_6_max_max_min_min_min_min_t : {level_7_6_max_max_min_min_min_min_t[0+:DATA_WIDTH],level_7_6_max_max_min_min_min_min_t[DATA_WIDTH+:DATA_WIDTH]};
    assign level_7_6_max_min_max_max_max_max = (level_7_6_max_min_max_max_max_max_t[0+:DATA_WIDTH]>level_7_6_max_min_max_max_max_max_t[DATA_WIDTH+:DATA_WIDTH]) ? level_7_6_max_min_max_max_max_max_t : {level_7_6_max_min_max_max_max_max_t[0+:DATA_WIDTH],level_7_6_max_min_max_max_max_max_t[DATA_WIDTH+:DATA_WIDTH]};
    assign level_7_6_max_min_max_max_max_min = (level_7_6_max_min_max_max_max_min_t[0+:DATA_WIDTH]>level_7_6_max_min_max_max_max_min_t[DATA_WIDTH+:DATA_WIDTH]) ? level_7_6_max_min_max_max_max_min_t : {level_7_6_max_min_max_max_max_min_t[0+:DATA_WIDTH],level_7_6_max_min_max_max_max_min_t[DATA_WIDTH+:DATA_WIDTH]};
    assign level_7_6_max_min_max_max_min_max = (level_7_6_max_min_max_max_min_max_t[0+:DATA_WIDTH]>level_7_6_max_min_max_max_min_max_t[DATA_WIDTH+:DATA_WIDTH]) ? level_7_6_max_min_max_max_min_max_t : {level_7_6_max_min_max_max_min_max_t[0+:DATA_WIDTH],level_7_6_max_min_max_max_min_max_t[DATA_WIDTH+:DATA_WIDTH]};
    assign level_7_6_max_min_max_max_min_min = (level_7_6_max_min_max_max_min_min_t[0+:DATA_WIDTH]>level_7_6_max_min_max_max_min_min_t[DATA_WIDTH+:DATA_WIDTH]) ? level_7_6_max_min_max_max_min_min_t : {level_7_6_max_min_max_max_min_min_t[0+:DATA_WIDTH],level_7_6_max_min_max_max_min_min_t[DATA_WIDTH+:DATA_WIDTH]};
    assign level_7_6_max_min_max_min_max_max = (level_7_6_max_min_max_min_max_max_t[0+:DATA_WIDTH]>level_7_6_max_min_max_min_max_max_t[DATA_WIDTH+:DATA_WIDTH]) ? level_7_6_max_min_max_min_max_max_t : {level_7_6_max_min_max_min_max_max_t[0+:DATA_WIDTH],level_7_6_max_min_max_min_max_max_t[DATA_WIDTH+:DATA_WIDTH]};
    assign level_7_6_max_min_max_min_max_min = (level_7_6_max_min_max_min_max_min_t[0+:DATA_WIDTH]>level_7_6_max_min_max_min_max_min_t[DATA_WIDTH+:DATA_WIDTH]) ? level_7_6_max_min_max_min_max_min_t : {level_7_6_max_min_max_min_max_min_t[0+:DATA_WIDTH],level_7_6_max_min_max_min_max_min_t[DATA_WIDTH+:DATA_WIDTH]};
    assign level_7_6_max_min_max_min_min_max = (level_7_6_max_min_max_min_min_max_t[0+:DATA_WIDTH]>level_7_6_max_min_max_min_min_max_t[DATA_WIDTH+:DATA_WIDTH]) ? level_7_6_max_min_max_min_min_max_t : {level_7_6_max_min_max_min_min_max_t[0+:DATA_WIDTH],level_7_6_max_min_max_min_min_max_t[DATA_WIDTH+:DATA_WIDTH]};
    assign level_7_6_max_min_max_min_min_min = (level_7_6_max_min_max_min_min_min_t[0+:DATA_WIDTH]>level_7_6_max_min_max_min_min_min_t[DATA_WIDTH+:DATA_WIDTH]) ? level_7_6_max_min_max_min_min_min_t : {level_7_6_max_min_max_min_min_min_t[0+:DATA_WIDTH],level_7_6_max_min_max_min_min_min_t[DATA_WIDTH+:DATA_WIDTH]};
    assign level_7_6_max_min_min_max_max_max = (level_7_6_max_min_min_max_max_max_t[0+:DATA_WIDTH]>level_7_6_max_min_min_max_max_max_t[DATA_WIDTH+:DATA_WIDTH]) ? level_7_6_max_min_min_max_max_max_t : {level_7_6_max_min_min_max_max_max_t[0+:DATA_WIDTH],level_7_6_max_min_min_max_max_max_t[DATA_WIDTH+:DATA_WIDTH]};
    assign level_7_6_max_min_min_max_max_min = (level_7_6_max_min_min_max_max_min_t[0+:DATA_WIDTH]>level_7_6_max_min_min_max_max_min_t[DATA_WIDTH+:DATA_WIDTH]) ? level_7_6_max_min_min_max_max_min_t : {level_7_6_max_min_min_max_max_min_t[0+:DATA_WIDTH],level_7_6_max_min_min_max_max_min_t[DATA_WIDTH+:DATA_WIDTH]};
    assign level_7_6_max_min_min_max_min_max = (level_7_6_max_min_min_max_min_max_t[0+:DATA_WIDTH]>level_7_6_max_min_min_max_min_max_t[DATA_WIDTH+:DATA_WIDTH]) ? level_7_6_max_min_min_max_min_max_t : {level_7_6_max_min_min_max_min_max_t[0+:DATA_WIDTH],level_7_6_max_min_min_max_min_max_t[DATA_WIDTH+:DATA_WIDTH]};
    assign level_7_6_max_min_min_max_min_min = (level_7_6_max_min_min_max_min_min_t[0+:DATA_WIDTH]>level_7_6_max_min_min_max_min_min_t[DATA_WIDTH+:DATA_WIDTH]) ? level_7_6_max_min_min_max_min_min_t : {level_7_6_max_min_min_max_min_min_t[0+:DATA_WIDTH],level_7_6_max_min_min_max_min_min_t[DATA_WIDTH+:DATA_WIDTH]};
    assign level_7_6_max_min_min_min_max_max = (level_7_6_max_min_min_min_max_max_t[0+:DATA_WIDTH]>level_7_6_max_min_min_min_max_max_t[DATA_WIDTH+:DATA_WIDTH]) ? level_7_6_max_min_min_min_max_max_t : {level_7_6_max_min_min_min_max_max_t[0+:DATA_WIDTH],level_7_6_max_min_min_min_max_max_t[DATA_WIDTH+:DATA_WIDTH]};
    assign level_7_6_max_min_min_min_max_min = (level_7_6_max_min_min_min_max_min_t[0+:DATA_WIDTH]>level_7_6_max_min_min_min_max_min_t[DATA_WIDTH+:DATA_WIDTH]) ? level_7_6_max_min_min_min_max_min_t : {level_7_6_max_min_min_min_max_min_t[0+:DATA_WIDTH],level_7_6_max_min_min_min_max_min_t[DATA_WIDTH+:DATA_WIDTH]};
    assign level_7_6_max_min_min_min_min_max = (level_7_6_max_min_min_min_min_max_t[0+:DATA_WIDTH]>level_7_6_max_min_min_min_min_max_t[DATA_WIDTH+:DATA_WIDTH]) ? level_7_6_max_min_min_min_min_max_t : {level_7_6_max_min_min_min_min_max_t[0+:DATA_WIDTH],level_7_6_max_min_min_min_min_max_t[DATA_WIDTH+:DATA_WIDTH]};
    assign level_7_6_max_min_min_min_min_min = (level_7_6_max_min_min_min_min_min_t[0+:DATA_WIDTH]>level_7_6_max_min_min_min_min_min_t[DATA_WIDTH+:DATA_WIDTH]) ? level_7_6_max_min_min_min_min_min_t : {level_7_6_max_min_min_min_min_min_t[0+:DATA_WIDTH],level_7_6_max_min_min_min_min_min_t[DATA_WIDTH+:DATA_WIDTH]};
    assign level_7_6_min_max_max_max_max_max = (level_7_6_min_max_max_max_max_max_t[0+:DATA_WIDTH]>level_7_6_min_max_max_max_max_max_t[DATA_WIDTH+:DATA_WIDTH]) ? level_7_6_min_max_max_max_max_max_t : {level_7_6_min_max_max_max_max_max_t[0+:DATA_WIDTH],level_7_6_min_max_max_max_max_max_t[DATA_WIDTH+:DATA_WIDTH]};
    assign level_7_6_min_max_max_max_max_min = (level_7_6_min_max_max_max_max_min_t[0+:DATA_WIDTH]>level_7_6_min_max_max_max_max_min_t[DATA_WIDTH+:DATA_WIDTH]) ? level_7_6_min_max_max_max_max_min_t : {level_7_6_min_max_max_max_max_min_t[0+:DATA_WIDTH],level_7_6_min_max_max_max_max_min_t[DATA_WIDTH+:DATA_WIDTH]};
    assign level_7_6_min_max_max_max_min_max = (level_7_6_min_max_max_max_min_max_t[0+:DATA_WIDTH]>level_7_6_min_max_max_max_min_max_t[DATA_WIDTH+:DATA_WIDTH]) ? level_7_6_min_max_max_max_min_max_t : {level_7_6_min_max_max_max_min_max_t[0+:DATA_WIDTH],level_7_6_min_max_max_max_min_max_t[DATA_WIDTH+:DATA_WIDTH]};
    assign level_7_6_min_max_max_max_min_min = (level_7_6_min_max_max_max_min_min_t[0+:DATA_WIDTH]>level_7_6_min_max_max_max_min_min_t[DATA_WIDTH+:DATA_WIDTH]) ? level_7_6_min_max_max_max_min_min_t : {level_7_6_min_max_max_max_min_min_t[0+:DATA_WIDTH],level_7_6_min_max_max_max_min_min_t[DATA_WIDTH+:DATA_WIDTH]};
    assign level_7_6_min_max_max_min_max_max = (level_7_6_min_max_max_min_max_max_t[0+:DATA_WIDTH]>level_7_6_min_max_max_min_max_max_t[DATA_WIDTH+:DATA_WIDTH]) ? level_7_6_min_max_max_min_max_max_t : {level_7_6_min_max_max_min_max_max_t[0+:DATA_WIDTH],level_7_6_min_max_max_min_max_max_t[DATA_WIDTH+:DATA_WIDTH]};
    assign level_7_6_min_max_max_min_max_min = (level_7_6_min_max_max_min_max_min_t[0+:DATA_WIDTH]>level_7_6_min_max_max_min_max_min_t[DATA_WIDTH+:DATA_WIDTH]) ? level_7_6_min_max_max_min_max_min_t : {level_7_6_min_max_max_min_max_min_t[0+:DATA_WIDTH],level_7_6_min_max_max_min_max_min_t[DATA_WIDTH+:DATA_WIDTH]};
    assign level_7_6_min_max_max_min_min_max = (level_7_6_min_max_max_min_min_max_t[0+:DATA_WIDTH]>level_7_6_min_max_max_min_min_max_t[DATA_WIDTH+:DATA_WIDTH]) ? level_7_6_min_max_max_min_min_max_t : {level_7_6_min_max_max_min_min_max_t[0+:DATA_WIDTH],level_7_6_min_max_max_min_min_max_t[DATA_WIDTH+:DATA_WIDTH]};
    assign level_7_6_min_max_max_min_min_min = (level_7_6_min_max_max_min_min_min_t[0+:DATA_WIDTH]>level_7_6_min_max_max_min_min_min_t[DATA_WIDTH+:DATA_WIDTH]) ? level_7_6_min_max_max_min_min_min_t : {level_7_6_min_max_max_min_min_min_t[0+:DATA_WIDTH],level_7_6_min_max_max_min_min_min_t[DATA_WIDTH+:DATA_WIDTH]};
    assign level_7_6_min_max_min_max_max_max = (level_7_6_min_max_min_max_max_max_t[0+:DATA_WIDTH]>level_7_6_min_max_min_max_max_max_t[DATA_WIDTH+:DATA_WIDTH]) ? level_7_6_min_max_min_max_max_max_t : {level_7_6_min_max_min_max_max_max_t[0+:DATA_WIDTH],level_7_6_min_max_min_max_max_max_t[DATA_WIDTH+:DATA_WIDTH]};
    assign level_7_6_min_max_min_max_max_min = (level_7_6_min_max_min_max_max_min_t[0+:DATA_WIDTH]>level_7_6_min_max_min_max_max_min_t[DATA_WIDTH+:DATA_WIDTH]) ? level_7_6_min_max_min_max_max_min_t : {level_7_6_min_max_min_max_max_min_t[0+:DATA_WIDTH],level_7_6_min_max_min_max_max_min_t[DATA_WIDTH+:DATA_WIDTH]};
    assign level_7_6_min_max_min_max_min_max = (level_7_6_min_max_min_max_min_max_t[0+:DATA_WIDTH]>level_7_6_min_max_min_max_min_max_t[DATA_WIDTH+:DATA_WIDTH]) ? level_7_6_min_max_min_max_min_max_t : {level_7_6_min_max_min_max_min_max_t[0+:DATA_WIDTH],level_7_6_min_max_min_max_min_max_t[DATA_WIDTH+:DATA_WIDTH]};
    assign level_7_6_min_max_min_max_min_min = (level_7_6_min_max_min_max_min_min_t[0+:DATA_WIDTH]>level_7_6_min_max_min_max_min_min_t[DATA_WIDTH+:DATA_WIDTH]) ? level_7_6_min_max_min_max_min_min_t : {level_7_6_min_max_min_max_min_min_t[0+:DATA_WIDTH],level_7_6_min_max_min_max_min_min_t[DATA_WIDTH+:DATA_WIDTH]};
    assign level_7_6_min_max_min_min_max_max = (level_7_6_min_max_min_min_max_max_t[0+:DATA_WIDTH]>level_7_6_min_max_min_min_max_max_t[DATA_WIDTH+:DATA_WIDTH]) ? level_7_6_min_max_min_min_max_max_t : {level_7_6_min_max_min_min_max_max_t[0+:DATA_WIDTH],level_7_6_min_max_min_min_max_max_t[DATA_WIDTH+:DATA_WIDTH]};
    assign level_7_6_min_max_min_min_max_min = (level_7_6_min_max_min_min_max_min_t[0+:DATA_WIDTH]>level_7_6_min_max_min_min_max_min_t[DATA_WIDTH+:DATA_WIDTH]) ? level_7_6_min_max_min_min_max_min_t : {level_7_6_min_max_min_min_max_min_t[0+:DATA_WIDTH],level_7_6_min_max_min_min_max_min_t[DATA_WIDTH+:DATA_WIDTH]};
    assign level_7_6_min_max_min_min_min_max = (level_7_6_min_max_min_min_min_max_t[0+:DATA_WIDTH]>level_7_6_min_max_min_min_min_max_t[DATA_WIDTH+:DATA_WIDTH]) ? level_7_6_min_max_min_min_min_max_t : {level_7_6_min_max_min_min_min_max_t[0+:DATA_WIDTH],level_7_6_min_max_min_min_min_max_t[DATA_WIDTH+:DATA_WIDTH]};
    assign level_7_6_min_max_min_min_min_min = (level_7_6_min_max_min_min_min_min_t[0+:DATA_WIDTH]>level_7_6_min_max_min_min_min_min_t[DATA_WIDTH+:DATA_WIDTH]) ? level_7_6_min_max_min_min_min_min_t : {level_7_6_min_max_min_min_min_min_t[0+:DATA_WIDTH],level_7_6_min_max_min_min_min_min_t[DATA_WIDTH+:DATA_WIDTH]};
    assign level_7_6_min_min_max_max_max_max = (level_7_6_min_min_max_max_max_max_t[0+:DATA_WIDTH]>level_7_6_min_min_max_max_max_max_t[DATA_WIDTH+:DATA_WIDTH]) ? level_7_6_min_min_max_max_max_max_t : {level_7_6_min_min_max_max_max_max_t[0+:DATA_WIDTH],level_7_6_min_min_max_max_max_max_t[DATA_WIDTH+:DATA_WIDTH]};
    assign level_7_6_min_min_max_max_max_min = (level_7_6_min_min_max_max_max_min_t[0+:DATA_WIDTH]>level_7_6_min_min_max_max_max_min_t[DATA_WIDTH+:DATA_WIDTH]) ? level_7_6_min_min_max_max_max_min_t : {level_7_6_min_min_max_max_max_min_t[0+:DATA_WIDTH],level_7_6_min_min_max_max_max_min_t[DATA_WIDTH+:DATA_WIDTH]};
    assign level_7_6_min_min_max_max_min_max = (level_7_6_min_min_max_max_min_max_t[0+:DATA_WIDTH]>level_7_6_min_min_max_max_min_max_t[DATA_WIDTH+:DATA_WIDTH]) ? level_7_6_min_min_max_max_min_max_t : {level_7_6_min_min_max_max_min_max_t[0+:DATA_WIDTH],level_7_6_min_min_max_max_min_max_t[DATA_WIDTH+:DATA_WIDTH]};
    assign level_7_6_min_min_max_max_min_min = (level_7_6_min_min_max_max_min_min_t[0+:DATA_WIDTH]>level_7_6_min_min_max_max_min_min_t[DATA_WIDTH+:DATA_WIDTH]) ? level_7_6_min_min_max_max_min_min_t : {level_7_6_min_min_max_max_min_min_t[0+:DATA_WIDTH],level_7_6_min_min_max_max_min_min_t[DATA_WIDTH+:DATA_WIDTH]};
    assign level_7_6_min_min_max_min_max_max = (level_7_6_min_min_max_min_max_max_t[0+:DATA_WIDTH]>level_7_6_min_min_max_min_max_max_t[DATA_WIDTH+:DATA_WIDTH]) ? level_7_6_min_min_max_min_max_max_t : {level_7_6_min_min_max_min_max_max_t[0+:DATA_WIDTH],level_7_6_min_min_max_min_max_max_t[DATA_WIDTH+:DATA_WIDTH]};
    assign level_7_6_min_min_max_min_max_min = (level_7_6_min_min_max_min_max_min_t[0+:DATA_WIDTH]>level_7_6_min_min_max_min_max_min_t[DATA_WIDTH+:DATA_WIDTH]) ? level_7_6_min_min_max_min_max_min_t : {level_7_6_min_min_max_min_max_min_t[0+:DATA_WIDTH],level_7_6_min_min_max_min_max_min_t[DATA_WIDTH+:DATA_WIDTH]};
    assign level_7_6_min_min_max_min_min_max = (level_7_6_min_min_max_min_min_max_t[0+:DATA_WIDTH]>level_7_6_min_min_max_min_min_max_t[DATA_WIDTH+:DATA_WIDTH]) ? level_7_6_min_min_max_min_min_max_t : {level_7_6_min_min_max_min_min_max_t[0+:DATA_WIDTH],level_7_6_min_min_max_min_min_max_t[DATA_WIDTH+:DATA_WIDTH]};
    assign level_7_6_min_min_max_min_min_min = (level_7_6_min_min_max_min_min_min_t[0+:DATA_WIDTH]>level_7_6_min_min_max_min_min_min_t[DATA_WIDTH+:DATA_WIDTH]) ? level_7_6_min_min_max_min_min_min_t : {level_7_6_min_min_max_min_min_min_t[0+:DATA_WIDTH],level_7_6_min_min_max_min_min_min_t[DATA_WIDTH+:DATA_WIDTH]};
    assign level_7_6_min_min_min_max_max_max = (level_7_6_min_min_min_max_max_max_t[0+:DATA_WIDTH]>level_7_6_min_min_min_max_max_max_t[DATA_WIDTH+:DATA_WIDTH]) ? level_7_6_min_min_min_max_max_max_t : {level_7_6_min_min_min_max_max_max_t[0+:DATA_WIDTH],level_7_6_min_min_min_max_max_max_t[DATA_WIDTH+:DATA_WIDTH]};
    assign level_7_6_min_min_min_max_max_min = (level_7_6_min_min_min_max_max_min_t[0+:DATA_WIDTH]>level_7_6_min_min_min_max_max_min_t[DATA_WIDTH+:DATA_WIDTH]) ? level_7_6_min_min_min_max_max_min_t : {level_7_6_min_min_min_max_max_min_t[0+:DATA_WIDTH],level_7_6_min_min_min_max_max_min_t[DATA_WIDTH+:DATA_WIDTH]};
    assign level_7_6_min_min_min_max_min_max = (level_7_6_min_min_min_max_min_max_t[0+:DATA_WIDTH]>level_7_6_min_min_min_max_min_max_t[DATA_WIDTH+:DATA_WIDTH]) ? level_7_6_min_min_min_max_min_max_t : {level_7_6_min_min_min_max_min_max_t[0+:DATA_WIDTH],level_7_6_min_min_min_max_min_max_t[DATA_WIDTH+:DATA_WIDTH]};
    assign level_7_6_min_min_min_max_min_min = (level_7_6_min_min_min_max_min_min_t[0+:DATA_WIDTH]>level_7_6_min_min_min_max_min_min_t[DATA_WIDTH+:DATA_WIDTH]) ? level_7_6_min_min_min_max_min_min_t : {level_7_6_min_min_min_max_min_min_t[0+:DATA_WIDTH],level_7_6_min_min_min_max_min_min_t[DATA_WIDTH+:DATA_WIDTH]};
    assign level_7_6_min_min_min_min_max_max = (level_7_6_min_min_min_min_max_max_t[0+:DATA_WIDTH]>level_7_6_min_min_min_min_max_max_t[DATA_WIDTH+:DATA_WIDTH]) ? level_7_6_min_min_min_min_max_max_t : {level_7_6_min_min_min_min_max_max_t[0+:DATA_WIDTH],level_7_6_min_min_min_min_max_max_t[DATA_WIDTH+:DATA_WIDTH]};
    assign level_7_6_min_min_min_min_max_min = (level_7_6_min_min_min_min_max_min_t[0+:DATA_WIDTH]>level_7_6_min_min_min_min_max_min_t[DATA_WIDTH+:DATA_WIDTH]) ? level_7_6_min_min_min_min_max_min_t : {level_7_6_min_min_min_min_max_min_t[0+:DATA_WIDTH],level_7_6_min_min_min_min_max_min_t[DATA_WIDTH+:DATA_WIDTH]};
    assign level_7_6_min_min_min_min_min_max = (level_7_6_min_min_min_min_min_max_t[0+:DATA_WIDTH]>level_7_6_min_min_min_min_min_max_t[DATA_WIDTH+:DATA_WIDTH]) ? level_7_6_min_min_min_min_min_max_t : {level_7_6_min_min_min_min_min_max_t[0+:DATA_WIDTH],level_7_6_min_min_min_min_min_max_t[DATA_WIDTH+:DATA_WIDTH]};
    assign level_7_6_min_min_min_min_min_min = (level_7_6_min_min_min_min_min_min_t[0+:DATA_WIDTH]>level_7_6_min_min_min_min_min_min_t[DATA_WIDTH+:DATA_WIDTH]) ? level_7_6_min_min_min_min_min_min_t : {level_7_6_min_min_min_min_min_min_t[0+:DATA_WIDTH],level_7_6_min_min_min_min_min_min_t[DATA_WIDTH+:DATA_WIDTH]};

    assign level_7_w = {
                                 level_7_6_min_min_min_min_min_min,level_7_6_min_min_min_min_min_max,
                                 level_7_6_min_min_min_min_max_min,level_7_6_min_min_min_min_max_max,
                                 level_7_6_min_min_min_max_min_min,level_7_6_min_min_min_max_min_max,
                                 level_7_6_min_min_min_max_max_min,level_7_6_min_min_min_max_max_max,
                                 level_7_6_min_min_max_min_min_min,level_7_6_min_min_max_min_min_max,
                                 level_7_6_min_min_max_min_max_min,level_7_6_min_min_max_min_max_max,
                                 level_7_6_min_min_max_max_min_min,level_7_6_min_min_max_max_min_max,
                                 level_7_6_min_min_max_max_max_min,level_7_6_min_min_max_max_max_max,
                                 level_7_6_min_max_min_min_min_min,level_7_6_min_max_min_min_min_max,
                                 level_7_6_min_max_min_min_max_min,level_7_6_min_max_min_min_max_max,
                                 level_7_6_min_max_min_max_min_min,level_7_6_min_max_min_max_min_max,
                                 level_7_6_min_max_min_max_max_min,level_7_6_min_max_min_max_max_max,
                                 level_7_6_min_max_max_min_min_min,level_7_6_min_max_max_min_min_max,
                                 level_7_6_min_max_max_min_max_min,level_7_6_min_max_max_min_max_max,
                                 level_7_6_min_max_max_max_min_min,level_7_6_min_max_max_max_min_max,
                                 level_7_6_min_max_max_max_max_min,level_7_6_min_max_max_max_max_max,
                                 level_7_6_max_min_min_min_min_min,level_7_6_max_min_min_min_min_max,
                                 level_7_6_max_min_min_min_max_min,level_7_6_max_min_min_min_max_max,
                                 level_7_6_max_min_min_max_min_min,level_7_6_max_min_min_max_min_max,
                                 level_7_6_max_min_min_max_max_min,level_7_6_max_min_min_max_max_max,
                                 level_7_6_max_min_max_min_min_min,level_7_6_max_min_max_min_min_max,
                                 level_7_6_max_min_max_min_max_min,level_7_6_max_min_max_min_max_max,
                                 level_7_6_max_min_max_max_min_min,level_7_6_max_min_max_max_min_max,
                                 level_7_6_max_min_max_max_max_min,level_7_6_max_min_max_max_max_max,
                                 level_7_6_max_max_min_min_min_min,level_7_6_max_max_min_min_min_max,
                                 level_7_6_max_max_min_min_max_min,level_7_6_max_max_min_min_max_max,
                                 level_7_6_max_max_min_max_min_min,level_7_6_max_max_min_max_min_max,
                                 level_7_6_max_max_min_max_max_min,level_7_6_max_max_min_max_max_max,
                                 level_7_6_max_max_max_min_min_min,level_7_6_max_max_max_min_min_max,
                                 level_7_6_max_max_max_min_max_min,level_7_6_max_max_max_min_max_max,
                                 level_7_6_max_max_max_max_min_min,level_7_6_max_max_max_max_min_max,
                                 level_7_6_max_max_max_max_max_min,level_7_6_max_max_max_max_max_max};
    
    always@(posedge clk or negedge rst_n)
    begin
        if (!rst_n)
            level_7_r <= 'd0;
        else if(level_6_c_valid[1] && !ascend_6)
            level_7_r <= {level_7_r[0+:64*DATA_WIDTH],level_6_c_r};
        else
            level_7_r <= level_7_r;
    end
    
    always@(posedge clk or negedge rst_n)
    begin
        if(!rst_n)
            level_7_c_r <= 'd0;
        else
            level_7_c_r <= level_7_w;
    end
    
    always@(posedge clk or negedge rst_n)
    begin
        if(!rst_n)
            ascend_7 <= 1'b0;
        else if(level_6_c_valid[1] && !ascend_6)
            ascend_7 <= ~ascend_7;
    end
    
    always@(posedge clk or negedge rst_n)
    begin
        if (!rst_n)
            level_7_c_valid <= 'd0;
        else
            level_7_c_valid <= {level_7_c_valid[0],level_6_c_valid[1] & !ascend_6};
    end
    
    //构建第8级双调
    reg [256*DATA_WIDTH-1:0] level_8_r;
    reg [DATA_WIDTH-1:0] level_8_c_r;
    reg ascend_8;
    reg [1:0] level_8_c_valid;
    wire [128*DATA_WIDTH-1:0] level_8_1_max;
    wire [128*DATA_WIDTH-1:0] level_8_1_min;
    
    wire [64*DATA_WIDTH-1:0] level_8_2_max_min_t;
    wire [64*DATA_WIDTH-1:0] level_8_2_min_max_t;
    
    wire [32*DATA_WIDTH-1:0] level_8_3_max_min_min_t;
    wire [32*DATA_WIDTH-1:0] level_8_3_min_max_max_t;
    
    wire [16*DATA_WIDTH-1:0] level_8_4_max_min_min_min_t;
    wire [16*DATA_WIDTH-1:0] level_8_4_min_max_max_max_t;
    
    wire [8*DATA_WIDTH-1:0] level_8_5_max_min_min_min_min_t;
    wire [8*DATA_WIDTH-1:0] level_8_5_min_max_max_max_max_t;
    
    wire [4*DATA_WIDTH-1:0] level_8_6_max_min_min_min_min_min_t;     
    wire [4*DATA_WIDTH-1:0] level_8_6_min_max_max_max_max_max_t;
    
    wire [2*DATA_WIDTH-1:0] level_8_7_max_min_min_min_min_min_min_t;
    wire [2*DATA_WIDTH-1:0] level_8_7_min_max_max_max_max_max_max_t;
    
    wire [DATA_WIDTH-1:0] level_8_7_max_med;
    wire [DATA_WIDTH-1:0] level_8_7_min_med;
    
    wire [DATA_WIDTH-1:0] level_8_w;

    
    generate
    for (i=0;i<128;i=i+1)
        begin:gen_8_1
            assign level_8_1_max[i*DATA_WIDTH+:DATA_WIDTH] = (level_8_r[(256-i)*DATA_WIDTH-1-:DATA_WIDTH] >level_8_r[i*DATA_WIDTH+:DATA_WIDTH]) ? level_8_r[(256-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_8_r[i*DATA_WIDTH+:DATA_WIDTH];   
            assign level_8_1_min[i*DATA_WIDTH+:DATA_WIDTH] = (level_8_r[(256-i)*DATA_WIDTH-1-:DATA_WIDTH] >level_8_r[i*DATA_WIDTH+:DATA_WIDTH]) ?  level_8_r[i*DATA_WIDTH+:DATA_WIDTH] : level_8_r[(256-i)*DATA_WIDTH-1-:DATA_WIDTH];
        end
    endgenerate
    
    generate
    for (i=0;i<64;i=i+1)
        begin:gen_8_2
            assign level_8_2_max_min_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_8_1_max[(128-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_8_1_max[(64-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_8_1_max[(64-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_8_1_max[(128-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_8_2_min_max_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_8_1_min[(128-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_8_1_min[(64-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_8_1_min[(128-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_8_1_min[(64-i)*DATA_WIDTH-1-:DATA_WIDTH];       
        end
    endgenerate
    
    generate
    for (i=0;i<32;i=i+1)
        begin:gen_8_3
            assign level_8_3_max_min_min_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_8_2_max_min_t[(64-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_8_2_max_min_t[(32-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_8_2_max_min_t[(32-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_8_2_max_min_t[(64-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_8_3_min_max_max_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_8_2_min_max_t[(64-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_8_2_min_max_t[(32-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_8_2_min_max_t[(64-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_8_2_min_max_t[(32-i)*DATA_WIDTH-1-:DATA_WIDTH];
        end
    endgenerate
    
    generate
    for (i=0;i<16;i=i+1)
        begin:gen_8_4
            assign level_8_4_max_min_min_min_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_8_3_max_min_min_t[(32-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_8_3_max_min_min_t[(16-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_8_3_max_min_min_t[(16-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_8_3_max_min_min_t[(32-i)*DATA_WIDTH-1-:DATA_WIDTH];          
            assign level_8_4_min_max_max_max_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_8_3_min_max_max_t[(32-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_8_3_min_max_max_t[(16-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_8_3_min_max_max_t[(32-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_8_3_min_max_max_t[(16-i)*DATA_WIDTH-1-:DATA_WIDTH];
        end
    endgenerate    
    
    generate
    for (i=0;i<8;i=i+1)
        begin:gen_8_5
            assign level_8_5_max_min_min_min_min_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_8_4_max_min_min_min_t[(16-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_8_4_max_min_min_min_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_8_4_max_min_min_min_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_8_4_max_min_min_min_t[(16-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_8_5_min_max_max_max_max_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_8_4_min_max_max_max_t[(16-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_8_4_min_max_max_max_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_8_4_min_max_max_max_t[(16-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_8_4_min_max_max_max_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH];
        end
    endgenerate
    
    generate
    for (i=0;i<4;i=i+1)
        begin:gen_8_6
            assign level_8_6_max_min_min_min_min_min_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_8_5_max_min_min_min_min_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_8_5_max_min_min_min_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_8_5_max_min_min_min_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_8_5_max_min_min_min_min_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_8_6_min_max_max_max_max_max_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_8_5_min_max_max_max_max_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_8_5_min_max_max_max_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_8_5_min_max_max_max_max_t[(8-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_8_5_min_max_max_max_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH];
        end
    endgenerate  
    
    generate
    for (i=0;i<2;i=i+1)
        begin:gen_8_7
            assign level_8_7_max_min_min_min_min_min_min_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_8_6_max_min_min_min_min_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_8_6_max_min_min_min_min_min_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_8_6_max_min_min_min_min_min_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_8_6_max_min_min_min_min_min_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH];
            assign level_8_7_min_max_max_max_max_max_max_t[i*DATA_WIDTH+:DATA_WIDTH] = (level_8_6_min_max_max_max_max_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH]>level_8_6_min_max_max_max_max_max_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH]) ? level_8_6_min_max_max_max_max_max_t[(4-i)*DATA_WIDTH-1-:DATA_WIDTH] : level_8_6_min_max_max_max_max_max_t[(2-i)*DATA_WIDTH-1-:DATA_WIDTH];
        end
    endgenerate  
    
    assign level_8_7_max_med = (level_8_7_max_min_min_min_min_min_min_t[0+:DATA_WIDTH]>level_8_7_max_min_min_min_min_min_min_t[DATA_WIDTH+:DATA_WIDTH]) ? level_8_7_max_min_min_min_min_min_min_t[DATA_WIDTH+:DATA_WIDTH] : level_8_7_max_min_min_min_min_min_min_t[0+:DATA_WIDTH];
    assign level_8_7_min_med = (level_8_7_min_max_max_max_max_max_max_t[0+:DATA_WIDTH]>level_8_7_min_max_max_max_max_max_max_t[DATA_WIDTH+:DATA_WIDTH]) ? level_8_7_min_max_max_max_max_max_max_t[0+:DATA_WIDTH] : level_8_7_min_max_max_max_max_max_max_t[DATA_WIDTH+:DATA_WIDTH];

    assign level_8_w = (level_8_7_max_med + level_8_7_min_med)/2;
    
    always@(posedge clk or negedge rst_n)
    begin
        if (!rst_n)
            level_8_r <= 'd0;
        else if(level_7_c_valid[1] && !ascend_7)
            level_8_r <= {level_8_r[0+:128*DATA_WIDTH],level_7_c_r};
        else
            level_8_r <= level_8_r;
    end
    
    always@(posedge clk or negedge rst_n)
    begin
        if(!rst_n)
            level_8_c_r <= 'd0;
        else
            level_8_c_r <= level_8_w;
    end
    
    always@(posedge clk or negedge rst_n)
    begin
        if(!rst_n)
            ascend_8 <= 1'b0;
        else if(level_7_c_valid[1] && !ascend_7)
            ascend_8 <= ~ascend_8;
    end
    
    always@(posedge clk or negedge rst_n)
    begin
        if (!rst_n)
            level_8_c_valid <= 'd0;
        else
            level_8_c_valid <= {level_8_c_valid[0],level_7_c_valid[1] & !ascend_7};
    end
    
    always@(posedge clk or negedge rst_n)begin
        if(!rst_n)
            ref_data <='d0;
        else if(level_8_c_valid[1] && !ascend_8)
            ref_data <= level_8_c_r;
    end
    
    always@(posedge clk or negedge rst_n)begin
        if(!rst_n)
            ref_valid <='d0;
        else
            ref_valid <= level_8_c_valid & (!ascend_8) ;
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


