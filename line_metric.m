
function q = line_metric(I, fr, rg, pxC, pyC, tag)
%LINE_METRIC  只对"曲线笔画"计算重合度（这是判断"像不像原图"的正确口径）
%
%   为什么不能直接数墨迹像素：散点、误差棒、灰色单次记录、图例文字、坐标轴刻度、
%   参考虚线都不是曲线；而且同一根笔画越粗，路径覆盖的像素比例天然越低
%   （12 px 粗的线，路径穿心也只占 5/12 = 42%）。所以按"每一列上的每一段曲线
%   笔画有没有被认领"来算，并按长度加权。
%
%   返回 q.cover(长度加权重合度) / q.onLine / q.cen / q.nRun / q.wLine / q.bigGap / q.gap(漏检掩膜)
[ink, wLine] = ink_for_figure(I, fr, tag);
d = double(I); [H,W,~] = size(d);
rT=max(1,round(fr(1))+3); rB=min(H,round(fr(2))-3);
cL=max(1,round(fr(3))+3); cR=min(W,round(fr(4))-3);
line = ink;

line = bwareaopen(line, 10, 8);
% 路径掩膜
mask = false(H,W);
for k = 1:numel(pxC)
   P=[pxC{k}(:) pyC{k}(:)]; P=P(all(isfinite(P),2),:);
   for t=1:size(P,1)
      c=round(P(t,1)); r=round(P(t,2));
      if r>=1&&r<=H&&c>=1&&c<=W, mask(max(1,r-2):min(r+2,H),c)=true; end
   end
end
maskH = imdilate(mask, strel('rectangle',[5 5]));   % 行/列各 ±2
gap = false(H,W);
nRun=0; nCov=0; errs=[]; bigGap=0; lenTot=0; lenCov=0;
minLen = max(3, round(0.25*wLine));
for c = cL:cR
   rr = find(line(:,c)); if isempty(rr), continue; end
   bk = [0;find(diff(rr)>2);numel(rr)];
   for t = 1:numel(bk)-1
      gr = rr(bk(t)+1:bk(t+1)); if numel(gr)<minLen, continue; end
      nRun=nRun+1; lenTot=lenTot+numel(gr);
      if any(maskH(gr(1):gr(end), c))
         nCov=nCov+1; lenCov=lenCov+numel(gr);
         if numel(gr) <= 2.0*wLine
            dj = find(mask(gr(1):gr(end), c));
            if ~isempty(dj), errs(end+1)=abs(gr(1)+mean(dj)-1-mean(gr)); end %#ok<AGROW>
         end
      else
         gap(gr,c) = true;
         if numel(gr) >= 1.5*wLine, bigGap = bigGap + 1; end
      end
   end
end
q = struct('cover', lenCov/max(1,lenTot), 'coverN', nCov/max(1,nRun), ...
   'onLine', sum(sum(line & mask))/max(1,sum(mask(:))), 'cen', median(errs), ...
   'nRun', nRun, 'wLine', wLine, 'bigGap', bigGap, 'gap', gap);
end

function v = getfielddef(s,f,d), if isfield(s,f), v=s.(f); else, v=d; end, end
