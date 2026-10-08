
function render_check()
%RENDER_CHECK  生成"诚实"的核对图：原图淡化 + 提取出的**中心线**（1 px），
%              并按"偏离墨迹中心"的多少着色：绿 <=0.5px、黄 <=1.5px、红 >1.5px。
%   为什么不用粗线叠加：笔画宽 9~13 px，画 3 px 的品红线时两侧必然露出原色，
%   看起来像"没重合"，其实中心线是重合的。1 px 中心线 + 偏差着色才看得准。
here = fileparts(mfilename('fullpath')); cd(here);
S = fig_specs_v2();
for i = 1:numel(S)
   tag = S(i).tag;
   I = imread(fullfile('data', S(i).img)); if size(I,3)==1, I=repmat(I,1,1,3); end
   L = load(fullfile('digitized_final',[tag '.mat'])); CR = L.CR;
   [ink, wLine] = ink_for_figure(I, S(i).frame, tag);
   d0 = double(I); g = mean(d0,3)/255; ch = (max(d0,[],3)-min(d0,[],3))/255;
   V = max(1-g, ch); [H,W] = size(V);
   base = uint8(255 - (255-double(rgb2gray(I)))*0.35);   % 淡化原图
   O = repmat(base,1,1,3);
   stat = zeros(1,numel(CR));
   for k = 1:numel(CR)
      cs = CR(k).px(:); rs = CR(k).py(:);
      for q = 1:numel(cs)
         c = cs(q); if c<1||c>W, continue; end
         rr = find(ink(:,c)); best = [];
         if ~isempty(rr)
            bk=[0;find(diff(rr)>2);numel(rr)];
            for t=1:numel(bk)-1
               gr=rr(bk(t)+1:bk(t+1));
               if rs(q)>=gr(1)-2 && rs(q)<=gr(end)+2, best=gr; break; end
            end
         end
         dev = NaN;
         if ~isempty(best)
            a=max(1,best(1)-2); b=min(H,best(end)+2); wgt=V(a:b,c);
            if sum(wgt)>1e-6, dev = abs(rs(q) - sum((a:b)'.*wgt)/sum(wgt)); end
         end
         if ~isfinite(dev), col = [120 120 120];        % 无墨迹(被遮挡/合并)灰
         elseif dev <= 0.5, col = [0 170 0];
         elseif dev <= 1.5, col = [230 170 0];
         else,              col = [230 0 0];
         end
         r = round(rs(q));
         if r>=1 && r<=H, O(r,c,:) = reshape(col,1,1,3); stat(k)=stat(k)+ (isfinite(dev)&&dev>1.5); end
      end
   end
   fr = S(i).frame; m = 30;
   r0=max(1,round(fr(1))-m); r1=min(H,round(fr(2))+m);
   c0=max(1,round(fr(3))-m); c1=min(W,round(fr(4))+m);
   imwrite(O(r0:r1,c0:c1,:), fullfile('qa',[tag '_check.png']));
   fprintf('%-6s 红色(>1.5px)列数: %s\n', tag, mat2str(stat));
end
disp('核对图已生成：qa/<tag>_check.png  (绿<=0.5px 黄<=1.5px 红>1.5px 灰=被遮挡)');
end
