//
//  JDORealTimeController.m
//  YTBus
//
//  Created by zhang yi on 14-10-21.
//  Copyright (c) 2014年 胶东在线. All rights reserved.
//

#import "JDORealTimeController.h"
#import "BMapKit.h"
#import "JDOBusLineDetail.h"
#import "JDOStationModel.h"
#import "JDODatabase.h"
#import "JDORealTimeCell.h"
#import "JDORealTimeMapController.h"

@interface JDORealTimeController (){
    NSMutableArray *_stations;
    FMDatabase *_db;
    id dbObserver;
}

@property (nonatomic,assign) IBOutlet UILabel *lineDetail;
@property (nonatomic,assign) IBOutlet UILabel *startTime;
@property (nonatomic,assign) IBOutlet UILabel *endTime;
@property (nonatomic,assign) IBOutlet UILabel *price;
@property (nonatomic,assign) IBOutlet UIButton *directionBtn;
@property (nonatomic,assign) IBOutlet UIButton *favorBtn;
@property (nonatomic,assign) IBOutlet UITableView *tableView;

- (IBAction)changeDirection:(id)sender;
- (IBAction)clickFavor:(id)sender;

@end

@implementation JDORealTimeController

- (void)viewDidLoad {
    [super viewDidLoad];
    
    self.navigationItem.title = _busLine.lineName;
    self.navigationItem.rightBarButtonItem.enabled = false;
    
    _stations = [NSMutableArray new];
    _db = [JDODatabase sharedDB];
    if (_db) {
        [self loadData];
    }
    dbObserver = [[NSNotificationCenter defaultCenter] addObserverForName:@"db_changed" object:nil queue:nil usingBlock:^(NSNotification *note) {
        _db = [JDODatabase sharedDB];
        [self loadData];
    }];
}

- (void)prepareForSegue:(UIStoryboardSegue *)segue sender:(id)sender {
    if ([segue.identifier isEqualToString:@"toRealtimeMap"]) {
        JDORealTimeMapController *rt = segue.destinationViewController;
        rt.stations = _stations;
    }
}

- (void)loadData{
    
    if(!_busLine.lineDetailPair){   // 从线路进入时，没有lineDetail，需要从数据库加载
        _busLine.lineDetailPair = [NSMutableArray new];
        NSString *getDetailIdByLineId = @"select ID from BusLineDetail where BUSLINEID = ?";
        FMResultSet *rs = [_db executeQuery:getDetailIdByLineId,_busLine.lineId];
        while ([rs next]) {
            JDOBusLineDetail *aLineDetail = [JDOBusLineDetail new];
            aLineDetail.detailId = [rs stringForColumn:@"ID"];
            [_busLine.lineDetailPair addObject:aLineDetail];
        }
        if(_busLine.lineDetailPair.count == 0){
            NSLog(@"线路无详情数据");
            return;
        }
        _busLine.showingIndex = 0;
    }
    JDOBusLineDetail *lineDetail = _busLine.lineDetailPair[_busLine.showingIndex];
    NSString *lineDetailId = lineDetail.detailId;
    
    NSString *getDetailById = @"select BUSLINENAME,PRICE,FIRSTTIME,LASTTIME from BusLineDetail where id = ?";
    FMResultSet *rs = [_db executeQuery:getDetailById,lineDetailId];
    if ([rs next]) {
        _lineDetail.text = [rs stringForColumn:@"BUSLINENAME"];
        _startTime.text = [rs stringForColumn:@"FIRSTTIME"];
        _endTime.text = [rs stringForColumn:@"LASTTIME"];
        _price.text = [NSString stringWithFormat:@"%g",[rs doubleForColumn:@"PRICE"]];
    }
    
    [_stations removeAllObjects];
    rs = [_db executeQuery:GetStationsByLineDetail,lineDetailId];
    while ([rs next]) {
        JDOStationModel *station = [JDOStationModel new];
        station.fid = [rs stringForColumn:@"STATIONID"];
        station.name = [rs stringForColumn:@"STATIONNAME"];
        station.direction = [rs stringForColumn:@"DIRECTION"];
        station.gpsX = [NSNumber numberWithDouble:[rs doubleForColumn:@"GPSX"]];
        station.gpsY = [NSNumber numberWithDouble:[rs doubleForColumn:@"GPSY"]];
        [_stations addObject:station];
    }
    [_tableView reloadData];
    self.navigationItem.rightBarButtonItem.enabled = true;
    
    // 收藏标志
    NSArray *favorLineIds = [[NSUserDefaults standardUserDefaults] arrayForKey:@"favor_line"];
    if (favorLineIds) {
        for (int i=0; i<favorLineIds.count; i++) {
            NSString *lineId = favorLineIds[i];
            if([_busLine.lineId isEqualToString:lineId]){
                [_favorBtn setTitle:@"已收藏" forState:UIControlStateNormal];
                break;
            }
        }
    }
}

- (IBAction)changeDirection:(id)sender{
    
}

- (IBAction)clickFavor:(id)sender{
    NSString *title = [sender titleForState:UIControlStateNormal];
    NSMutableArray *favorLineIds = [[[NSUserDefaults standardUserDefaults] arrayForKey:@"favor_line"] mutableCopy];
    if(!favorLineIds){
        favorLineIds = [NSMutableArray new];
    }
    if ([title isEqualToString:@"收藏"]) {
        [favorLineIds addObject:_busLine.lineId];
        [_favorBtn setTitle:@"已收藏" forState:UIControlStateNormal];
    }else{
        [favorLineIds removeObject:_busLine.lineId];
        [_favorBtn setTitle:@"收藏" forState:UIControlStateNormal];
    }
    [[NSUserDefaults standardUserDefaults] setObject:favorLineIds forKey:@"favor_line"];
    [[NSUserDefaults standardUserDefaults] synchronize];
    
    [[NSNotificationCenter defaultCenter] postNotificationName:@"favor_line_changed" object:nil];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return [_stations count];
}


- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    JDORealTimeCell *cell = [tableView dequeueReusableCellWithIdentifier:@"lineStation" forIndexPath:indexPath];
    JDOStationModel *station = _stations[indexPath.row];

    [cell.stationName setText:station.name];
    
    if(_busLine.nearbyStationPair.count>0){
        JDOStationModel *startStation = _busLine.nearbyStationPair[_busLine.showingIndex];
        if ([station.fid isEqualToString:startStation.fid]) {
            cell.stationIcon.image = [UIImage imageNamed:@"first"];
            station.start = true;
        }else{
            cell.stationIcon.image = [UIImage imageNamed:@"second"];
        }
    }else{  // 从线路进入，则无法预知起点
        cell.stationIcon.image = [UIImage imageNamed:@"second"];
    }
    
    return cell;
}

- (void)didReceiveMemoryWarning {
    [super didReceiveMemoryWarning];
}

-(void)dealloc{
    if (dbObserver) {
        [[NSNotificationCenter defaultCenter] removeObserver:dbObserver];
    }
}

@end