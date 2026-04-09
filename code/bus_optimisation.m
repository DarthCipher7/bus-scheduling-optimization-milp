clear; clc; close all;

% LOAD DATA 
data = readtable('APSRTC_Transport_Data.xlsx');
vars = lower(string(data.Properties.VariableNames));

monthCol = find(contains(vars,'month'),1);
dayCol   = find(contains(vars,'day'),1);
routeCol = find(contains(vars,'route'),1);
passCol  = find(contains(vars,'pass'),1);
busCol   = find(contains(vars,'bus'),1);
typeCol  = find(contains(vars,'type'),1);
depotCol = find(contains(vars,'depot'),1);
fareCol  = find(contains(vars,'fare'),1);

% SAFE CONVERSION 
monthData = data{:,monthCol};
if ~isnumeric(monthData)
    monthData = double(categorical(monthData));
end

dayData = data{:,dayCol};
if ~isnumeric(dayData)
    dayData = str2double(string(dayData));
end

routeData = categorical(data{:,routeCol});
routeIDs  = double(routeData);
routeNames = categories(routeData);

busData   = string(data{:,busCol});
typeData  = string(data{:,typeCol});
depotData = string(data{:,depotCol});

passengers = data{:,passCol};

fareData = data{:,fareCol};
if ~isnumeric(fareData)
    fareData = str2double(string(fareData));
end

% DAILY AGGREGATION 
dayID = monthData*100 + dayData;
[uniqueDays,~,dayIdx] = unique(dayID);

numDays = length(uniqueDays);
R = length(routeNames);

dailyData = zeros(numDays,R);

for i = 1:height(data)
    d = dayIdx(i);
    r = routeIDs(i);
    dailyData(d,r) = dailyData(d,r) + passengers(i);
end

% DEMAND 
H = 24;

hourWeights = [
    0.01 0.01 0.01 0.01 0.02 0.04 ...
    0.08 0.12 0.15 0.12 0.08 0.05 ...
    0.04 0.04 0.05 0.07 0.10 0.12 ...
    0.10 0.08 0.05 0.03 0.02 0.01];

hourWeights = hourWeights / sum(hourWeights);

scaleFactor = 150;

avgDemand = 0.5*mean(dailyData,1) + 0.5*max(dailyData,[],1);

lambda_full = zeros(H,R);
for r = 1:R
    lambda_full(:,r) = avgDemand(r) * hourWeights' * scaleFactor;
end

% PARAMETERS 
C = 60;
cost_bus = 300;
cost_fuel = 500;
cost_slack = 10000;

B = round(0.6 * length(unique(busData)));

% TRAVEL TIME 
T = zeros(H,R);

for h = 1:H
    for r = 1:R
        if (h>=8 && h<=11) || (h>=17 && h<=20)
            T(h,r) = 50 + 8*r;
        else
            T(h,r) = 35 + 5*r;
        end
    end
end

trips = 60 ./ T;

% MILP 
nX = H*R;
nS = H*R;
dVar = nX + nS;

getIndex = @(h,r) (h-1)*R + r;

f = zeros(dVar,1);

for h = 1:H
    for r = 1:R
        f(getIndex(h,r)) = cost_bus + cost_fuel;
        f(nX + getIndex(h,r)) = cost_slack;
    end
end

A = [];
bvec = [];

for h = 1:H
    for r = 1:R
        row = zeros(1,dVar);
        row(getIndex(h,r)) = -C * trips(h,r);
        row(nX + getIndex(h,r)) = -1;
        
        A = [A; row];
        bvec = [bvec; -lambda_full(h,r)];
    end
end

for h = 1:H
    row = zeros(1,dVar);
    for r = 1:R
        row(getIndex(h,r)) = 1;
    end
    A = [A; row];
    bvec = [bvec; B];
end

lb = zeros(dVar,1);
intcon = 1:nX;

xopt = intlinprog(f,intcon,A,bvec,[],[],lb,[]);

Bcount = round(reshape(xopt(1:nX),[R,H])');

% SCHEDULE 
schedule = cell(100000,8);  
rowCounter = 0;

for r = 1:R
    
    routeMask = (routeIDs == r);
    
    routeTable = table( ...
        busData(routeMask), ...
        typeData(routeMask), ...
        depotData(routeMask), ...
        'VariableNames', {'BusID','BusType','Depot'});
    
    for h = 1:H
        
        numBuses = Bcount(h,r);
        n = height(routeTable);
        
        for i = 1:numBuses
            
            rowCounter = rowCounter + 1;
            idx = mod(i-1,n) + 1;
            
            passengersAssigned = ceil(lambda_full(h,r)/max(1,numBuses));
            
            % ONLY ADDITION
            slackPassengers = max(0, passengersAssigned - C);
            
            schedule(rowCounter,:) = {
                routeTable.BusID(idx), ...
                string(routeNames(r)), ...
                routeTable.BusType(idx), ...
                routeTable.Depot(idx), ...
                h, ...
                r, ...
                passengersAssigned, ...
                slackPassengers
            };
        end
    end
end

schedule = schedule(1:rowCounter,:);

scheduleTable = cell2table(schedule,...
'VariableNames',{'BusID','Route','BusType','Depot','Hour','RouteIndex','Passengers','SlackPassengers'});

disp('OPTIMIZED BUS SCHEDULE:')
disp(scheduleTable)
% ANALYTICS 
disp('=== ANALYTICS ===')

routeRevenue = zeros(R,1);
routeCost = zeros(R,1);

for r = 1:R
    
    routeDemand = lambda_full(:,r);
    routeFare = mean(fareData(routeIDs==r),'omitnan');
    
    routeRevenue(r) = sum(routeDemand * routeFare);
    routeCost(r) = sum(Bcount(:,r)) * (cost_bus + cost_fuel);
end

routeProfit = routeRevenue - routeCost;

revStr = compose('₹%.0f', routeRevenue);
costStr = compose('₹%.0f', routeCost);
profitStr = compose('₹%.0f', routeProfit);

T_display = table(routeNames, revStr, costStr, profitStr,...
    'VariableNames',{'Route','Revenue','Cost','Profit'});

disp(T_display)

% GRAPHS 

% Total demand over time
figure;
plot(1:H, sum(lambda_full,2),'LineWidth',2)
title('Total Demand')

% Demand heatmap
figure;
imagesc(lambda_full')
colorbar
title('Demand Heatmap')

% Revenue per route
figure;
bar(routeRevenue)
title('Revenue per Route')

% Profit per route
figure;
bar(routeProfit)
title('Profit per Route')

% PASSENGER vs HOUR 

targetRoute = "Eluru-Hyderabad";

rIndex = find(routeNames == targetRoute);

if ~isempty(rIndex)
    
    figure;
    plot(1:H, lambda_full(:,rIndex), '-o','LineWidth',2)
    
    title(['Passenger Demand vs Hour: ', char(targetRoute)])
    xlabel('Hour of Day')
    ylabel('Passengers')
    grid on
    
else
    disp('Route not found')
end

% PEAK VS OFF-PEAK

peakHours = [8 9 10 11 17 18 19 20];
offPeakHours = setdiff(1:H, peakHours);

peakDemand = sum(lambda_full(peakHours,:),1);
offPeakDemand = sum(lambda_full(offPeakHours,:),1);

figure;
bar([peakDemand; offPeakDemand]')
legend('Peak','Off-Peak')
title('Peak vs Off-Peak Demand per Route')
xlabel('Route Index')
ylabel('Passengers')

% AVERAGE DEMAND 

avgPeak = mean(lambda_full(peakHours,:),1);
avgOffPeak = mean(lambda_full(offPeakHours,:),1);

figure;
bar([avgPeak; avgOffPeak]')
title('Average Demand: Peak vs Off-Peak')
legend('Peak','Off-Peak')
xlabel('Route Index')
ylabel('Avg Passengers')
