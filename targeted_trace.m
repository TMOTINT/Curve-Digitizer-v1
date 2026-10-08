function [C, detail]=targeted_trace(I,C,fr,rg,opt)
%TARGETED_TRACE Strict color-specific observations, never gray-ink centroids.
% For curves with markers, reject marker/error-bar columns instead of giving
% them a small but nonzero weight. For same-color-family curves, require an
% exclusive color match. Only missing observations are linearly interpolated.
% No smoothing, curve fitting, or filtering is applied to observed coordinates.
if nargin<5,opt=struct();end
mode=getv(opt,'precisionMode','markers');n=numel(C);detail=cell(1,n);
if n==0,return;end
d=double(I);[H,W,~]=size(d);cores=vertcat(C.core);
% Use only spatially isolated track portions to estimate the solid ink color.
if strcmp(mode,'family')
    for k=1:n
        px=C(k).px(:);py=C(k).py(:);isolated=true(size(px));
        for j=1:n
            if j==k,continue;end
            yj=interp1(C(j).px,C(j).py,px,'linear',NaN);
            isolated=isolated & (isnan(yj)|abs(py-yj)>18);
        end
        good=find(isolated);samples=[];
        for t=good(1:3:end)'
            r=max(1,round(py(t))-3):min(H,round(py(t))+3);
            rgb=reshape(d(r,px(t),:),[],3);[~,jj]=min(sum(rgb(:,[1 3]),2));
            samples(end+1,:)=rgb(jj,:); %#ok<AGROW>
        end
        if size(samples,1)>30,cores(k,:)=median(samples,1);end
    end
end
for k=1:n
    cs=C(k).px(:);guide=C(k).py(:);nq=numel(cs);
    % Evaluate only the columns in the path. Memory stays bounded per curve.
    rgb=reshape(d(:,cs,:),[],3);v=255-cores(k,:);nv=sum(v.^2);
    if nv<1,continue;end
    p=255-rgb;alpha=max(0,min(1,p*v'/nv));
    residual=sum((p-alpha*v).^2,2);
    sigma=getv(opt,'colorSigma',20);
    V=reshape(alpha.*exp(-residual/sigma^2),H,nq);
    if strcmp(mode,'markers')
        % The fitted stroke and solid disk can have the same hue but different
        % RGB intensity (notably blue in 3E). Fitting a disk's exact RGB would
        % reject the real line. Opponent chroma keeps anti-alias coverage and
        % rejects the other colored series and neutral axes independently.
        [~,dominant]=max(cores(k,:));others=setdiff(1:3,dominant);
        chroma=max(0,rgb(:,dominant)-max(rgb(:,others),[],2));
        V=reshape(min(1,chroma/max(1,cores(k,dominant)-min(cores(k,others)))),H,nq);
    end
    if strcmp(mode,'family')
        % Identity comes from the opaque stroke color, not gray intensity.
        % At intersections one color may be occluded: no invented observation.
        dist=sum((rgb-cores(k,:)).^2,2);other=inf(size(dist));
        for j=1:n
            if j==k,continue;end
            other=min(other,sum((rgb-cores(j,:)).^2,2));
        end
        sep=sqrt(sum((cores-cores(k,:)).^2,2));sep(k)=inf;
        tol=max(10,min(25,.7*min(sep)));
        exclusive=reshape(dist<tol^2 & dist+9<other,H,nq);
        exclusive=bwareaopen(exclusive,12,8);
    else
        exclusive=true(H,nq);
    end
    block=getv(opt,'block',[]);
    if ~isempty(block)
        r=max(1,round(block(1))):min(H,round(block(2)));
        cols=cs>=block(3)&cs<=block(4);V(r,cols)=0;exclusive(r,cols)=false;
    end
    rT=max(1,ceil(fr(1))+3);rB=min(H,floor(fr(2))-3);
    V(1:rT-1,:)=0;V(rB+1:end,:)=0;
    exclusive(1:rT-1,:)=false;exclusive(rB+1:end,:)=false;
    measurement=nan(nq,1);width=nan(nq,1);mass=zeros(nq,1);
    candidates=cell(nq,1);
    if strcmp(mode,'family') && cores(k,2)<100,exclusive(1:min(H,rT+5),:)=false;end
    band=getv(opt,'searchBand',48);
    for q=1:nq
        if strcmp(mode,'family'),rr=find(exclusive(:,q));
        else,rr=find(V(:,q)>.15);end
        if isempty(rr),continue;end
        gap=1;if strcmp(mode,'family'),gap=5;end
        cuts=[0;find(diff(rr)>gap);numel(rr)];best=inf;
        for j=1:numel(cuts)-1
            run=rr(cuts(j)+1:cuts(j+1));
            lo=max(rT,run(1)-2);hi=min(rB,run(end)+2);w=V(lo:hi,q);
            if sum(w)<.3,continue;end
            if strcmp(mode,'family')
                own=find(exclusive(run,q));
                if numel(own)<2,continue;end
                % Center of exclusive opaque support avoids the neighboring
                % stroke entering the anti-aliased centroid near a crossing.
                row=mean(run(own));
            else
                row=sum((lo:hi)'.*w)/sum(w);
            end
            delta=abs(row-guide(q));if delta>band,continue;end
            if strcmp(mode,'family')
                candidates{q}(end+1,:)=[row,numel(run),max(w),delta];
            end
            merit=delta+.1*numel(run);
            if merit<best
                best=merit;measurement(q)=row;width(q)=numel(run);mass(q)=max(w);
            end
        end
    end
    if strcmp(mode,'family')
        [measurement,width,mass]=connectedEvidence(candidates);
    end
    valid=isfinite(measurement);if nnz(valid)<20,continue;end
    slope=gradient(guide);
    normalWidth=width./sqrt(1+slope.^2);
    baseWidth=max(2,prctile(normalWidth(valid),30));
    if strcmp(mode,'markers')
        % Full run thickness is measured before window clipping. A round
        % marker must not masquerade as a narrow measurement at its rim.
        thick=normalWidth>max(baseWidth+3,1.8*baseWidth);
        bad=movmax(double(thick),[3 3])>0;
        % Reject the entire horizontal extent of a nearby disk, including
        % its thin rim and error-bar caps. A thin cap is not a curve sample.
        distance=zeros(H,nq);
        for channel=1:3
            otherChannels=setdiff(1:3,channel);
            colorMask=reshape(rgb(:,channel)-max(rgb(:,otherChannels),[],2)>40,H,nq);
            distance=max(distance,bwdist(~colorMask));
        end
        diskColumn=false(nq,1);
        for q=1:nq
            radius=ceil(max(12,5*baseWidth));
            a=max(rT,round(guide(q))-radius);b=min(rB,round(guide(q))+radius);
            diskColumn(q)=any(distance(a:b,q)>max(3,baseWidth));
        end
        pad=ceil(baseWidth+5);
        bad=bad | movmax(double(diskColumn),[pad pad])>0;
    else
        bad=false(nq,1); % Color-connected family observations are already selected.
    end
    weight=double(valid & ~bad).*mass;
    m=measurement;m(~valid)=guide(~valid);
    if strcmp(mode,'family')
        [y,fit]=fillMissing(m,weight,guide,480,240);
    else
        [y,fit]=fillMissing(m,weight,guide,max(240,20*baseWidth));
    end
    y=min(max(y,rT),rB);
    C(k).py=y;C(k).X=rg(1)+(cs-fr(3))*diff(rg(1:2))/diff(fr(3:4));
    C(k).Y=rg(4)-(y-fr(1))*diff(rg(3:4))/diff(fr(1:2));
    detail{k}=struct('measurement',measurement,'weight',weight,'width',width, ...
        'baseWidth',baseWidth,'fit',fit,'core',cores(k,:),'guide',guide);
end
end
function [y,info]=fillMissing(m,w,guide,maxGap,maxEndpoint)
% Preserve every accepted pixel-center observation exactly. Fill only gaps
% bracketed by real evidence; short endpoints use a measured secant.
if nargin<5,maxEndpoint=80;end
y=guide;idx=find(w>0);
info=struct('nObserved',numel(idx),'nInterpolated',0);
if numel(idx)<2,return;end
y(idx)=m(idx);
for k=1:numel(idx)-1
    if idx(k+1)-idx(k)>maxGap,continue;end
    gaps=(idx(k)+1:idx(k+1)-1)';
    y(gaps)=interp1(idx(k:k+1),m(idx(k:k+1)),gaps,'linear');
    info.nInterpolated=info.nInterpolated+numel(gaps);
end
% Short endpoint occlusions: continue the secant through two measured points.
% This is extrapolation, not a smoothing fit; observed samples stay unchanged.
for side=1:2
    if side==1
        anchor=idx(1);other=idx(find(idx>=anchor+20,1));outside=(1:anchor-1)';
    else
        anchor=idx(end);other=idx(find(idx<=anchor-20,1,'last'));outside=(anchor+1:numel(y))';
    end
    if isempty(other)||isempty(outside)||max(abs(outside-anchor))>maxEndpoint,continue;end
    y(outside)=m(anchor)+(outside-anchor)*(m(other)-m(anchor))/(other-anchor);
end
end
function v=getv(s,f,d),if isfield(s,f),v=s.(f);else,v=d;end,end

function [m,width,mass]=connectedEvidence(candidates)
% Select original color observations as a globally connected path. This only
% chooses among pixel-supported candidates; it never averages/filter-fits Y.
n=numel(candidates);nodes=[];
for q=1:n
    if ~isempty(candidates{q})
        a=candidates{q};nodes=[nodes;repmat(q,size(a,1),1),a]; %#ok<AGROW>
    end
end
m=nan(n,1);width=nan(n,1);mass=zeros(n,1);
if isempty(nodes),return;end
N=size(nodes,1);score=-inf(N,1);parent=zeros(N,1);tangent=nan(N,1);first=1;
for i=1:N
    q=nodes(i,1);row=nodes(i,2);
    while nodes(first,1)<q-480,first=first+1;end
    previous=(first:i-1)';dx=q-nodes(previous,1);
    dy=abs(row-nodes(previous,2));
    allowed=dx>0 & dy<=3*dx+.5;
    previous=previous(allowed);dx=dx(allowed);dy=dy(allowed);
    gain=1+.05*min(nodes(i,3),5)-.002*nodes(i,5);
    score(i)=gain-.1*(q-nodes(1,1));
    if ~isempty(previous)
        direction=(row-nodes(previous,2))./dx;
        turn=abs(atan(direction)-atan(tangent(previous)));turn(~isfinite(turn))=0;
        % A branch change must agree with the incoming stroke direction.
        % This selects evidence; it does not alter any selected coordinate.
        values=score(previous)-.25*(dx-1)-.01*dy-2*max(0,turn-.5);
        [best,j]=max(values);
        if best+gain>score(i)
            score(i)=best+gain;parent(i)=previous(j);
            anchor=parent(i);
            while parent(anchor)>0 && q-nodes(anchor,1)<12,anchor=parent(anchor);end
            tangent(i)=(row-nodes(anchor,2))/(q-nodes(anchor,1));
        end
    end
end
[~,i]=max(score-.1*(nodes(end,1)-nodes(:,1)));
while i>0
    q=nodes(i,1);m(q)=nodes(i,2);width(q)=nodes(i,3);mass(q)=nodes(i,4);
    i=parent(i);
end
end
