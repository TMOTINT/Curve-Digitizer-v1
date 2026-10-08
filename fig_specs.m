function S = fig_specs()
%FIG_SPECS  单幅图标定表 —— 直接转发到自动实测标定表 fig_specs_v2.m
%
%   为什么改成转发：
%     本文件原本是手写量程表，其中 fig2E 的 y 零点偏 40 px（≈9.8 nm）、
%     fig3C 比例尺偏 1.9%、fig3E 顶端偏 3.5 nm、fig3F 的 x 量程整体写错，
%     这正是"曲线与原图重合度很差"的根因。
%     现在唯一可信来源是 calib_v2.m 实测出来的 fig_specs_v2.m，
%     于是所有旧脚本（extract_figs / t_app2 / t_anchor / ...）无需改一行代码
%     就拿到了修正标定；要显式写也可以，把 fig_specs() 换成 fig_specs_v2() 即可。
%
%   重新标定：  calib_v2      （实测轴脊/刻度/标注 -> 覆盖 fig_specs_v2.m）
%   旧表存档：  fig_specs_legacy.m
S = fig_specs_v2();
end
