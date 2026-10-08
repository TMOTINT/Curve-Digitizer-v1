
function check_flip()
%CHECK_FLIP  只统计"分离区内"的顺序翻转 —— 合并区里两条线本来就分不开，
%            那里的翻转没有意义（数值噪声）。分离区（|Δy| > 3 倍线宽）里翻转
%            才是真问题：说明跟踪跳线了。
here = fileparts(mfilename('fullpath')); cd(here);
S = fig_specs_v2();
fprintf('%-6s %10s %10s %10s\n','tag','显著翻转总数','单对最多','涉及对数');
for i = 1:numel(S)
   tag = S(i).tag;
   I = imread(fullfile('data', S(i).img)); if size(I,3)==1, I=repmat(I,1,1,3); end
   L = load(fullfile('digitized_final',[tag '.mat'])); CR = L.CR;
   [~, wLine] = ink_for_figure(I, S(i).frame, tag);
   W = size(I,2); n = numel(CR);
   Yk = nan(n, W);
   for k=1:n, Yk(k,:) = interp1(CR(k).px, CR(k).py, (1:W), 'linear', NaN); end
   tot = 0; mx = 0; np = 0;
   for k=1:n
      for l=k+1:n
         dy = Yk(k,:) - Yk(l,:);
         sep = abs(dy) > 3*wLine;
         s = sign(dy); s(~sep) = 0;
         % 只在"两侧都分离"的情况下比较
         v = s(s~=0);
         if numel(v) < 30, continue; end
         f = sum(abs(diff(v)) > 0);
         if f > 0, np = np + 1; end
         tot = tot + f; mx = max(mx, f);
      end
   end
   fprintf('%-6s %10d %10d %10d\n', tag, tot, mx, np);
end
end
