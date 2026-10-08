
function check_calib()
%CHECK_CALIB  独立校验坐标标定
%   原理：图里 x=0 / y=0 的虚线参考线，经标定表换算后数据坐标必须 ≈ 0。
%   这条线与轴框、量程的来源（刻度）完全独立，所以是对"坐标准不准"最硬的检查。
here = fileparts(mfilename('fullpath')); cd(here);
S = fig_specs_v2();
BLK = struct('fig2E',[1090 1270 860 2080],'fig3B',[840 1250 1220 2226], ...
             'fig3C',[840 1265 1310 2339],'fig3E',[210 600 1150 2165]);
fprintf('%-6s %12s %12s %12s\n','tag','y=0 换算值','y=0 占量程','x=0 换算值');
for i = 1:numel(S)
   tag = S(i).tag; fr = S(i).frame; rg = S(i).range;
   I = imread(fullfile('data', S(i).img)); if size(I,3)==1, I=repmat(I,1,1,3); end
   d = double(I); [H,W,~] = size(I); g = mean(d,3)/255;
   b = getfielddef(BLK, tag, []);
   m = false(H,W);
   m(max(1,round(fr(1))+10):min(H,round(fr(2))-6), max(1,round(fr(3))+6):min(W,round(fr(4))-10)) = true;
   if ~isempty(b), m(max(1,b(1)):min(H,b(2)), max(1,b(3)):min(W,b(4))) = false; end
   % 只用中间 60% 的列（避开 x≈0 附近曲线与参考线重合的地方）
   cA = round(fr(3)+0.22*(fr(4)-fr(3))); cB = round(fr(4)-0.06*(fr(4)-fr(3)));
   gd = g < 0.5;
   yv = NaN; xv = NaN;
   rowSpan = find(any(m,2)); colSpan = find(any(m,1));
   fr2 = sum(gd(:,cA:cB) & m(:,cA:cB), 2) / (cB-cA+1);
   cand = rowSpan(fr2(rowSpan) > 0.28 & fr2(rowSpan) < 0.92);
   if ~isempty(cand)
      [~,j] = max(fr2(cand)); r0 = cand(j);
      win = max(1,r0-4):min(H,r0+4); w = fr2(win);
      r0 = sum(win(:).*w(:))/sum(w(:));              % 亚像素中心
      yv = rg(4) - (r0 - fr(1))*(rg(4)-rg(3))/(fr(2)-fr(1));
   end
   fv = sum(gd(rowSpan(1):rowSpan(end),:) & m(rowSpan(1):rowSpan(end),:), 1) / numel(rowSpan);
   cand2 = colSpan(fv(colSpan) > 0.28 & fv(colSpan) < 0.92);
   if ~isempty(cand2)
      [~,j] = max(fv(cand2)); cc0 = cand2(j);
      win = max(1,cc0-4):min(W,cc0+4); w = fv(win);
      cc0 = sum(win(:).*w(:))/sum(w(:));
      xv = rg(1) + (cc0 - fr(3))*(rg(2)-rg(1))/(fr(4)-fr(3));
   end
   showY = ~isnan(yv) && abs(yv) < 0.2*abs(rg(4)-rg(3));
   showX = ~isnan(xv) && abs(xv) < 0.2*abs(rg(2)-rg(1));
   fprintf('%-6s %12s %12s %12s\n', tag, ...
      tern(showY,sprintf('%+.4g',yv),'--'), ...
      tern(showY,sprintf('%.3f%%',100*abs(yv)/abs(rg(4)-rg(3))),'--'), ...
      tern(showX,sprintf('%+.4g',xv),'--'));
end
fprintf('\n-- 表示该图没有这条参考线。占量程就是标定的相对误差。\n');
end
function s = tern(c,a,b), if c, s=a; else, s=b; end, end
function v = getfielddef(s,f,d), if isfield(s,f), v=s.(f); else, v=d; end, end