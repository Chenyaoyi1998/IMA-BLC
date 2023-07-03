`timescale 1ns / 1ps
module ima_blc_7#(
    parameter DATA_WIDTH=8,
    parameter BPS_L=1,
    parameter BPN_L=100,
    parameter READ_PIXEL=16,
    parameter BPS_R=BPS_L+BPN_L+READ_PIXEL,
    parameter BPN_R=100
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
    reg ready_delay_r;//将ready信号打一拍用于将ready整形成上升沿信号
    reg [3*DATA_WIDTH-1:0] black_buffer_r;//缓存暗像素
    
    //指示black_buffer是否满
    reg black_buffer_full_r;
    reg [2:0] black_pixel_cnt_r;
    
    //缓存第一级比较结果
    reg [2*DATA_WIDTH-1:0] max_r;
    reg [3*DATA_WIDTH-1:0] med_r;
    reg [2*DATA_WIDTH-1:0] min_r;
    
    //区间中值累加
    reg [2*DATA_WIDTH-1:0] acc_sum;
    reg [7:0] med_cnt_r;
    
    //指示第二级比较数据有效
    wire sort_mxx_valid;
    
    //缓存第二级比较数据
    reg [3*DATA_WIDTH-1:0] final_sort_r;
    
    //缓存区间中值
    reg [DATA_WIDTH-1:0] final_med_r;
    
    //累加控制信号
    reg acc_valid_r1,acc_valid_r2;
    reg ref_en;
    wire ref_valid;
    
    //校正值
    wire [DATA_WIDTH-1:0] ref_data;
    
    //指示输入的像素为暗像素还是有效像素
    wire active_pixel_exist;
    wire black_pixel_exist;
    
    //反压信号
    wire ready;
    wire ready_i;
    
    //开始第一级比较
    wire sort_valid;
    
    //产生第一级比较结果
    wire [DATA_WIDTH-1:0] max_w,med_w,min_w;
    
    //产生第二级比较结果
    wire [DATA_WIDTH-1:0] maxmin,medmed,minmax;
    
    //产生区间中值
    wire [DATA_WIDTH-1:0] final_med;
    
    //产生行间复位信号
    wire reset_signal;
    reg o_ready_delay_r;
    reg [4:0] read_pixel_cnt;
    
    //------------------------------Combination Logic------------------------------//
    //指示输入的像素为暗像素还是有效像素
    assign active_pixel_exist = (pixel_cnt_r >=BPS_L+BPN_L) && (pixel_cnt_r<BPS_R);
    assign black_pixel_exist = ((pixel_cnt_r>=BPS_L) && (pixel_cnt_r<BPS_L+BPN_L)) || ((pixel_cnt_r>=BPS_R) && (pixel_cnt_r<BPS_R+BPN_R));
    
    //反压信号
    assign ready=i_ready&(!o_ready);
    assign ready_i = ready&(!ready_delay_r);
    
    //开始第一级比较
    assign sort_valid = black_buffer_full_r;
    
    //产生第一级比较结果
    comparator_w  #(
        .DATA_WIDTH(DATA_WIDTH)
    ) u_comparator(
        .data_befor    (black_buffer_r),
        .max              (max_w),
        .med              (med_w),
        .min               (min_w)
    );
    
    //产生第二级比较结果
    assign maxmin=max_r[2*DATA_WIDTH-1:DATA_WIDTH]>max_r[DATA_WIDTH-1:0] ? max_r[DATA_WIDTH-1:0] : max_r[2*DATA_WIDTH-1:DATA_WIDTH];
    assign minmax=min_r[2*DATA_WIDTH-1:DATA_WIDTH]<min_r[DATA_WIDTH-1:0] ? min_r[DATA_WIDTH-1:0] : min_r[2*DATA_WIDTH-1:DATA_WIDTH];
    med_w u_medmed(
        .data(med_r),
        .med(medmed)
    );
    
     //产生区间中值
     med_w u_fianal_med(
         .data(final_sort_r),
         .med(final_med)
     );
     
     //产生行间复位信号
     assign reset_signal = o_ready & (!o_ready_delay_r);
     
     //产生ready信号
     assign o_ready = read_pixel_cnt == 0;
    //------------------------------Timing Logic------------------------------//
    //整形ready信号
    always@(posedge clk or negedge rst_n)begin
        if(!rst_n)
            ready_delay_r <= 1'b0;
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
    
    //指示black_buffrer是否满了，可以进行下一级比较
    always@(posedge clk or negedge rst_n)begin
        if(!rst_n)
            black_pixel_cnt_r <= 'd0;
        else if(black_pixel_cnt_r == 'd6 && i_valid)
            black_pixel_cnt_r <= 'd0;
        else if(i_valid && black_pixel_exist)
            black_pixel_cnt_r <= black_pixel_cnt_r + 1;
    end
    
    //black_buffer
    always@(posedge clk or negedge rst_n)begin
        if(!rst_n)begin
            black_buffer_r <= 'd0;
            black_buffer_full_r <= 1'b0;end
        else if(i_valid && black_pixel_exist && (black_pixel_cnt_r!=3'd6))begin
            black_buffer_r <= {black_buffer_r[2*DATA_WIDTH-1:0],idata};
            black_buffer_full_r <= (black_pixel_cnt_r == 3'd2) || (black_pixel_cnt_r == 3'd5);end
        else begin
            black_buffer_r <= black_buffer_r;
            black_buffer_full_r <= 1'b0;end
    end
    
    //缓存第一级比较结果
    always@(posedge clk or negedge rst_n)begin
        if(!rst_n)begin
            {max_r,med_r,min_r} <= 'd0;
        end
        else if(sort_valid)begin
            max_r <= {max_r[2*DATA_WIDTH-1:0],max_w};
            med_r <= {med_r[2*DATA_WIDTH-1:0],med_w};
            min_r <= {min_r[2*DATA_WIDTH-1:0],min_w};
        end
        else if(i_valid && black_pixel_exist && (black_pixel_cnt_r==3'd6))begin
           max_r <= max_r;
           med_r <= {med_r[2*DATA_WIDTH-1:0],idata};
           min_r <= min_r;
        end
    end
    
    //指示第二级比较数据有效
    sort_mxx_valid u_sort_mxx_7(
         .clk                            (clk),
         .rst_n                         (rst_n),
         .sort_valid                  (sort_valid),
         .pixel_cnt                   (pixel_cnt_r),
         .i_valid                       (i_valid),
         .black_pixel_exist        (black_pixel_exist),
         .black_pixel_cnt          (black_pixel_cnt_r),
         .o_valid                      (sort_mxx_valid)
    );
    
    //缓存第二级比较数据
    always@(posedge clk or negedge rst_n)begin
        if(!rst_n)
            final_sort_r <= 'd0;
        else if(sort_mxx_valid)
            final_sort_r <= {minmax,medmed,maxmin};
    end
    
    //缓存区间中值并产生累加控制信号
    always@(posedge clk or negedge rst_n)begin
        if(!rst_n)begin
            final_med_r <= 'd0;
            {acc_valid_r1,acc_valid_r2,ref_en} <= 3'b0;end
        else begin
            final_med_r <= final_med;
            {acc_valid_r1,acc_valid_r2,ref_en} <= {sort_mxx_valid,acc_valid_r1,acc_valid_r2};end
    end
    
    //将区间中值累加
    always@(posedge clk or negedge rst_n)begin
        if(!rst_n)begin
            acc_sum <= 'd0;
            med_cnt_r <= 'd0;end
        else if(reset_signal)begin//TODO
            acc_sum <= 'd0;
            med_cnt_r <= 'd0;end
        else if(acc_valid_r2)begin
            acc_sum <= acc_sum + final_med_r;
            med_cnt_r <= med_cnt_r + 1;end
    end
    
    //产生校正值
    divider #(
        .N(2*DATA_WIDTH),
        .M(8),
        .O(1 +( ((BPN_L + BPN_R) / 7) - 1)*2)
    )u_divider(
        .clk(clk),
        .rstn(rst_n),
        .data_rdy(ref_en),
        .dividend(acc_sum),
        .divisor(med_cnt_r),
        .res_o(ref_valid),
        .merchant(ref_data)
    );
    
    //产生行间复位信号
    always@(posedge clk or negedge rst_n)begin
        if(!rst_n)
            o_ready_delay_r <= 1'b0;
        else
            o_ready_delay_r <= o_ready;
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
        else if(ready_i&&(!o_ready))begin
            odata <= line_buffer_r[READ_PIXEL*DATA_WIDTH-1:(READ_PIXEL-1)*DATA_WIDTH] - ref_data;
            o_valid <= 1'b1;
        end
        else
            o_valid <= 1'b0;
    end
endmodule
