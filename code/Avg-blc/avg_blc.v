`timescale 1ns / 1ps
module avg_blc #(
    parameter DATA_WIDTH=8,
    parameter BPS_L=1,
    parameter BPN_L=9,
    parameter READ_PIXEL=16,
    parameter BPS_R=BPS_L+BPN_L+READ_PIXEL,
    parameter BPN_R=9
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
    reg ready_delay_r;//将ready信号打一拍用于将ready整形成上升沿信号
//    reg [9*DATA_WIDTH-1:0] black_buffer_r;//缓存暗像素
    
    //产生行间复位信号
    wire reset_signal;
    reg o_ready_delay_r;
    reg [4:0] read_pixel_cnt;
    
    //区间中值累加
    reg [2*DATA_WIDTH-1:0] acc_sum;
    reg [7:0] med_cnt_r;
    
    reg ref_en;
    
    //校正值
    wire ref_valid;
    wire [DATA_WIDTH-1:0] ref_data;
    
    //指示输入的像素为暗像素还是有效像素
    wire active_pixel_exist;
    wire black_pixel_exist;
    
    //反压信号
    wire ready;
    wire ready_i;
    
    //------------------------------Combination Logic------------------------------//
    //指示输入的像素为暗像素还是有效像素
    assign active_pixel_exist = (pixel_cnt_r >=BPS_L+BPN_L) && (pixel_cnt_r<BPS_R);
    assign black_pixel_exist = ((pixel_cnt_r>=BPS_L) && (pixel_cnt_r<BPS_L+BPN_L)) || ((pixel_cnt_r>=BPS_R) && (pixel_cnt_r<BPS_R+BPN_R));
    
    //反压信号
    assign ready=i_ready&(!o_ready);
    assign ready_i = ready&(!ready_delay_r);
    
    //产生行间复位信号
     assign o_ready = read_pixel_cnt == 0;
     assign reset_signal = o_ready & (!o_ready_delay_r);
    //------------------------------Timing Logic------------------------------//
    //整形ready信号
    always@(posedge clk or negedge rst_n)begin
        if(!rst_n)
            ready_delay_r <= 'd0;
        else
            ready_delay_r <= ready;
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
        else if(ready_i&&(!o_ready))
            line_buffer_r <= line_buffer_r<<DATA_WIDTH;
    end
    
    //black_buffer_acc
    always@(posedge clk or negedge rst_n)begin
        if(!rst_n)begin
            acc_sum <= 'd0;
            med_cnt_r <= 'd0;
        end
        else if(reset_signal)begin
            acc_sum <= 'd0;
            med_cnt_r <= 'd0;
        end
        else if(i_valid && black_pixel_exist)begin
            acc_sum <= acc_sum + idata;
            med_cnt_r <= med_cnt_r + 1;
        end
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
    
    //产生行间复位信号
    always@(posedge clk or negedge rst_n)begin
        if(!rst_n)
            o_ready_delay_r <= 1'b0;
        else
            o_ready_delay_r <= o_ready;
    end
    
    //产生校正值
    always@(posedge clk or negedge rst_n)begin
        if(!rst_n)
            ref_en <= 'd0;
        else
            ref_en <= i_valid && black_pixel_exist && (med_cnt_r <= (BPN_R+BPN_L));
    end
    
    divider #(
        .N(2*DATA_WIDTH),
        .M(8),
        .O(BPN_L + BPN_R)
    )u_divider(
        .clk(clk),
        .rstn(rst_n),
        .data_rdy(ref_en),
        .dividend(acc_sum),
        .divisor(med_cnt_r),
        .res_o(ref_valid),
        .merchant(ref_data)
    );
    
    //产生校正后像素值与o_valid信号
    always@(posedge clk or negedge rst_n)begin
        if(!rst_n)begin
            odata <= 'd0;
            o_valid <= 1'b0;
        end
        else if(ready_i&&(!o_ready))begin
            odata <= line_buffer_r[READ_PIXEL*DATA_WIDTH-1:(READ_PIXEL-1)*DATA_WIDTH] - ref_data;
            o_valid <= 1'b1;
        end
        else
            o_valid <= 1'b0;
    end
endmodule
