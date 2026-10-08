
function [ink, wLine, Dd] = ink_for_figure(I, fr, tag)
%INK_FOR_FIGURE  按图特征生成"曲线墨迹"掩膜（唯一来源，line_metric 与 audit 共用）
%   fig2E        只认黑色墨迹（灰色单次记录不是目标曲线）；灰色记录会压黑线，
%                把同一根笔画切成两段，用竖向闭运算接回来
%   fig3B/3C/3E  去掉圆点与误差棒（含帽）：竖向 run 明显长于线宽者，连同所在列一起剔除
%   fig3A/3D/3F  纯曲线，只需去轴脊、刻度线、图例
%   返回 ink（曲线墨迹）、wLine（笔画横向半宽，由距离变换脊值取中位）、Dd（到背景距离）
d = double(I); [H,W,~] = size(d);
g = mean(d,3)/255; ch = (max(d,[],3)-min(d,[],3))/255;
rT = max(1,round(fr(1))+3); rB = min(H,round(fr(2))-3);
cL = max(1,round(fr(3))+3); cR = min(W,round(fr(4))-3);
ink = false(H,W); ink(rT:rB,cL:cR) = (g(rT:rB,cL:cR)<0.88)|(ch(rT:rB,cL:cR)>0.08);
if strcmp(tag,'fig2E')
   ink = ink & (mean(d,3) < 110);
   ink = imclose(ink, strel('rectangle',[31 1]));
   f1 = mean(ink(:,cL:cR),2); for r = find(f1>0.28)', ink(max(1,r-3):min(H,r+3),:) = false; end
   f2 = mean(ink(rT:rB,:),1); for c = find(f2>0.20), ink(:,max(1,c-3):min(W,c+3)) = false; end
else
   f1 = mean(ink(:,cL:cR),2); for r = find(f1>0.45)', ink(max(1,r-4):min(H,r+4),:) = false; end
   f2 = mean(ink(rT:rB,:),1); for c = find(f2>0.35), ink(:,max(1,c-4):min(W,c+4)) = false; end
end
blk = struct('fig2E',[1090 1270 860 2080],'fig3B',[840 1250 1220 2226], ...
             'fig3C',[840 1265 1310 2339],'fig3E',[210 600 1150 2165]);
b = getfielddef(blk, tag, []);
if ~isempty(b)
   b = round(double(b(:)')); b = max(1, b);
   r0 = min(H,b(1)); r1 = min(H,b(2)); cc0 = min(W,b(3)); cc1 = min(W,b(4));
   if r1 >= r0 && cc1 >= cc0, ink(r0:r1, cc0:cc1) = false; end
end
CC = bwlabel(ink,8); st = regionprops(CC,'BoundingBox','PixelIdxList');
for t = 1:numel(st)
   bb = st(t).BoundingBox;
   touchLR = (bb(1)<=cL+10)||(bb(1)+bb(3)>=cR-10);
   touchTB = (bb(2)<=rT+10)||(bb(2)+bb(4)>=rB-10);
   if (touchLR&&bb(3)<0.06*(cR-cL)) || (touchTB&&bb(4)<0.12*(rB-rT))
      ink(st(t).PixelIdxList) = false;
   end
end
Dd = bwdist(~ink);
ridge = [];
for c = cL:cR
   rr = find(ink(:,c)); if isempty(rr), continue; end
   bk = [0;find(diff(rr)>2);numel(rr)];
   for t = 1:numel(bk)-1
      gr = rr(bk(t)+1:bk(t+1));
      ridge(end+1) = max(Dd(gr,c)); %#ok<AGROW>
   end
end
wLine = max(2, median(ridge));
switch tag
   case {'fig3B','fig3C','fig3E'}
      vr = zeros(H,W);
      for c = cL:cR
         rr = find(ink(:,c)); if isempty(rr), continue; end
         bk = [0;find(diff(rr)>2);numel(rr)];
         for t = 1:numel(bk)-1
            gr = rr(bk(t)+1:bk(t+1)); vr(gr,c) = numel(gr);
         end
      end
      seed = false(1,W);
      for c = cL:cR, if any(vr(:,c) > 3.5*wLine), seed(c) = true; end, end
      rad = max(6, round(1.2*wLine));
      for c = find(seed)
         cc = max(1,c-rad):min(W,c+rad);
         ink(:,cc) = false;
      end
end
end
function v = getfielddef(s,f,d), if isfield(s,f), v=s.(f); else, v=d; end, end
