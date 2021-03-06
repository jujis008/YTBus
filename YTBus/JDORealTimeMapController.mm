//
//  JDORealTimeMapController.m
//  YTBus
//
//  Created by zhang yi on 14-11-10.
//  Copyright (c) 2014年 胶东在线. All rights reserved.
//

#import "JDORealTimeMapController.h"
#import "JDOStationModel.h"
#import "JDOStationAnnotation.h"
#import "JDOConstants.h"
#import "JSONKit.h"
#import "JDOBusModel.h"
#import <objc/runtime.h>
#import "AppDelegate.h"

//BMKCircle只有静态构造函数，无法通过继承获得子类的具体类型，只能通过category添加属性

static const void *SelectedKey = &SelectedKey;

@interface BMKCircle (JDOCategory)

@property (nonatomic,retain) NSNumber *selected;

@end

@implementation BMKCircle (JDOCategory)

@dynamic selected;

- (NSNumber *)selected {
    return objc_getAssociatedObject(self, SelectedKey);
}

- (void)setSelected:(NSNumber *)selected{
    objc_setAssociatedObject(self, SelectedKey, selected, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

@end

@interface JDORealTimeMapController () <BMKMapViewDelegate,NSXMLParserDelegate>{
    int count;
    NSTimer *_timer;
    NSURLConnection *_connection;
    NSMutableData *_webData;
    NSMutableString *_jsonResult;
    BOOL isRecording;
    NSMutableArray *_buses;
    NSMutableArray *_drawedBusAnnotations;
    NSMutableArray *_stationAnnotations;
}

@end

@implementation JDORealTimeMapController

- (void)viewDidLoad {
    [super viewDidLoad];
    
    _mapView.zoomEnabled = true;
    _mapView.zoomEnabledWithTap = true;
    _mapView.scrollEnabled = true;
    _mapView.rotateEnabled = true;
    _mapView.overlookEnabled = false;
    _mapView.showMapScaleBar = false;
    _mapView.minZoomLevel = 12;
    _mapView.maxZoomLevel = 17;
    
    if (_stationId) {   // 存在起始站点，则以此站点为地图中心
        for (int i=0; i<_stations.count; i++) {
            JDOStationModel *station = _stations[i];
            if ([station.fid isEqualToString:_stationId]) {
                if (station.gpsY.doubleValue>0 && station.gpsX.doubleValue>0) {
                    _mapView.centerCoordinate = CLLocationCoordinate2DMake(station.gpsY.doubleValue,station.gpsX.doubleValue);
                    _mapView.zoomLevel = 15;
                }else{
                    _mapView.zoomLevel = 13;
                    [self setMapCenter];
                }
                break;
            }
        }
    }else{  // 否则以整条线路中心为地图中心
        _mapView.zoomLevel = 13;
        [self setMapCenter];
    }
    [self addStationOverlay];
    
    _buses = [NSMutableArray new];
    _drawedBusAnnotations = [NSMutableArray new];
    _stationAnnotations = [NSMutableArray new];
    if (_realBusList) {
        for (int i=0; i<_realBusList.count; i++){
            NSDictionary *dict = [_realBusList objectAtIndex:i];
            JDOBusModel *bus = [[JDOBusModel alloc] initWithDictionary:dict];
            [_buses addObject:bus];
        }
        [self redrawBus];
    }
}

- (void) setMapCenter{
    // 将地图的中心定位到所有站点的中心。所有站点的经纬度大致范围应该是北纬37-38，东经121-122
    double minX = 180, minY = 180, maxX = 0, maxY = 0;
    for (int i=0; i<_stations.count; i++) {
        JDOStationModel *station = _stations[i];
        // 有的站点没有gps数据
        if (station.gpsX.doubleValue == 0.0 || station.gpsY.doubleValue == 0.0) {
            continue;
        }
        if (station.gpsX.doubleValue < minX) {
            minX = station.gpsX.doubleValue;
        }
        if(station.gpsX.doubleValue > maxX ){
            maxX = station.gpsX.doubleValue;
        }
        if (station.gpsY.doubleValue < minY){
            minY = station.gpsY.doubleValue;
        }
        if(station.gpsY.doubleValue > maxY ){
            maxY = station.gpsY.doubleValue;
        }
    }
    _mapView.centerCoordinate = CLLocationCoordinate2DMake( (maxY+minY)/2, (maxX+minX)/2);
}

-(void)viewWillAppear:(BOOL)animated {
    [MobClick beginLogPageView:@"realtimemap"];
    [MobClick event:@"realtimemap"];
    [MobClick beginEvent:@"realtimemap"];
    
    _mapView.delegate = self;
    [_mapView viewWillAppear];
    
    int interval = [[NSUserDefaults standardUserDefaults] integerForKey:@"refresh_interval"]?:10;
    _timer = [NSTimer scheduledTimerWithTimeInterval:interval target:self selector:@selector(refreshData:) userInfo:nil repeats:true];
    [_timer fire];
}

-(void)viewWillDisappear:(BOOL)animated {
    [MobClick endLogPageView:@"realtimemap"];
    [MobClick endEvent:@"realtimemap"];
    
    [_mapView viewWillDisappear];
    _mapView.delegate = nil;
    if ( _timer && _timer.valid) {
        [_timer invalidate];
        _timer = nil;
    }
    if (_connection) {
        [_connection cancel];
    }
}

- (void) refreshData:(NSTimer *)timer{
    if ([UIApplication sharedApplication].applicationState != UIApplicationStateActive) {
        return;
    }
    // 最有可能的是从线路未选起始站点进入该界面，此时_stationId==nil
    if (!_stationId || !_lineId || !_lineStatus) {
        return;
    }
    NSString *soapMessage = [NSString stringWithFormat:GetBusLineStatus_SOAP_MSG,_stationId,_lineId,_lineStatus];
    AppDelegate *appDelegate = [UIApplication sharedApplication].delegate;
    NSString *port = appDelegate.systemParam[@"realtimePort"]?:Default_Realtime_Port;
    NSString *url = [NSString stringWithFormat:GetBusLineStatus_SOAP_URL,port];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url] cachePolicy:NSURLRequestReloadIgnoringCacheData timeoutInterval:URL_Request_Timeout];
    [request addValue:@"text/xml; charset=utf-8" forHTTPHeaderField:@"Content-Type"];
    [request addValue:[NSString stringWithFormat:@"%lu",(unsigned long)[soapMessage length]] forHTTPHeaderField:@"Content-Length"];
    [request addValue:@"http://www.dongfang-china.com/GetBusLineStatus" forHTTPHeaderField:@"SOAPAction"];
    [request setHTTPMethod:@"POST"];
    [request setHTTPBody:[soapMessage dataUsingEncoding:NSUTF8StringEncoding]];
    if (_connection) {
        [_connection cancel];
    }
    _connection = [NSURLConnection connectionWithRequest:request delegate:self];
    _webData = [NSMutableData data];
}

-(void)connection:(NSURLConnection *)connection didReceiveData:(NSData *)data{
    [_webData appendData:data];
}

-(void)connectionDidFinishLoading:(NSURLConnection *)connection{
    NSXMLParser *xmlParser = [[NSXMLParser alloc] initWithData: _webData];
    [xmlParser setDelegate: self];
    [xmlParser parse];
}

- (void)connection:(NSURLConnection *)connection didFailWithError:(NSError *)error{
    [JDOUtils showHUDText:[NSString stringWithFormat:@"连接服务器异常:%ld",(long)error.code] inView:self.view];
    NSLog(@"error:%@",error);
}

-(void)parser:(NSXMLParser *)parser didStartElement:(NSString *)elementName namespaceURI:(NSString *) namespaceURI qualifiedName:(NSString *)qName attributes: (NSDictionary *)attributeDict{
    if( [elementName isEqualToString:@"GetBusLineStatusResult"]){
        _jsonResult = [[NSMutableString alloc] init];
        isRecording = true;
    }
}

-(void)parser:(NSXMLParser *)parser foundCharacters:(NSString *)string{
    if( isRecording ){
        [_jsonResult appendString: string];
    }
}

-(void)parser:(NSXMLParser *)parser didEndElement:(NSString *)elementName namespaceURI:(NSString *)namespaceURI qualifiedName:(NSString *)qName{
    if( [elementName isEqualToString:@"GetBusLineStatusResult"]){
        NSLog(@"%@",_jsonResult);
        isRecording = false;
        if (_jsonResult.length==0 || [_jsonResult isEqualToString:@"[]"]) {
            NSString *info;
            if (_jsonResult.length==0) {
                info = @"无法获取实时数据";
            }else{
                info = @"没有下一班次数据";
            }
            [JDOUtils showHUDText:info inView:self.view];
            // 删除掉已经绘制的所有车辆，可能发生的情景是：最后一辆车开过参考站点，则要删除该车辆
            if (_buses.count>0) {
                [_buses removeAllObjects];
                [self redrawBus];
            }
        }else{
            NSArray *list = [_jsonResult objectFromJSONString];
            if (!list) {
                [JDOUtils showHUDText:@"实时数据格式错误" inView:self.view];
            }else{
                [_buses removeAllObjects];
                for (int i=0; i<list.count; i++){
                    NSDictionary *dict = [list objectAtIndex:i];
                    JDOBusModel *bus = [[JDOBusModel alloc] initWithDictionary:dict];
                    [_buses addObject:bus];
                }
                [self redrawBus];
            }
        }
    }
}

- (void)parser:(NSXMLParser *)parser parseErrorOccurred:(NSError *)parseError{
    [JDOUtils showHUDText:[NSString stringWithFormat:@"解析XML错误:%ld",(long)parseError.code] inView:self.view];
    NSLog(@"Error:%@",parseError);
}

- (void) redrawBus{
    // 删除上次绘制的车辆
    for (int i=0; i<_drawedBusAnnotations.count; i++) {
        [_mapView removeAnnotation:_drawedBusAnnotations[i]];
    }
    [_drawedBusAnnotations removeAllObjects];
    
    for (int i=0; i<_buses.count; i++){
        JDOBusModel *bus = _buses[i];
        JDOStationModel *nextStation;
        int nextStationIndex;
        for (int j=0; j<_stations.count-1; j++) {
            JDOStationModel *aStation = _stations[j];
            if ([aStation.fid isEqualToString:bus.toStationId]) {
                nextStation = _stations[j+1];
                nextStationIndex = j+1;
                break;
            }
        }
        CLLocationCoordinate2D busPos = BMKCoorDictionaryDecode(BMKConvertBaiduCoorFrom(CLLocationCoordinate2DMake(bus.gpsY.doubleValue, bus.gpsX.doubleValue),BMK_COORDTYPE_GPS));
        CLLocationCoordinate2D stationPos = CLLocationCoordinate2DMake(nextStation.gpsY.doubleValue, nextStation.gpsX.doubleValue);
        double distance = BMKMetersBetweenMapPoints(BMKMapPointForCoordinate(busPos),BMKMapPointForCoordinate(stationPos));
        
        for (int j=nextStationIndex; j<_stations.count-1; j++) {
            JDOStationModel *stationA = _stations[j];
            if (stationA.isStart) {
                break;
            }
            JDOStationModel *stationB = _stations[j+1];
            CLLocationCoordinate2D stationAPos = CLLocationCoordinate2DMake(stationA.gpsY.doubleValue, stationA.gpsX.doubleValue);
            CLLocationCoordinate2D stationBPos = CLLocationCoordinate2DMake(stationB.gpsY.doubleValue, stationB.gpsX.doubleValue);
            distance += BMKMetersBetweenMapPoints(BMKMapPointForCoordinate(stationAPos),BMKMapPointForCoordinate(stationBPos));
            
        }

        BMKPointAnnotation *annotation = [[BMKPointAnnotation alloc] init];
        annotation.coordinate = BMKCoorDictionaryDecode(BMKConvertBaiduCoorFrom(CLLocationCoordinate2DMake(bus.gpsY.doubleValue, bus.gpsX.doubleValue),BMK_COORDTYPE_GPS));
        if (bus.busNo == nil || [bus.busNo isEqualToString:@""]) {
            NSLog(@"没有车牌号");
        }
        annotation.title = bus.busNo;
        if (distance>999) {    //%.Ng代表N位有效数字(包括小数点前面的)，%.Nf代表N位小数位
            annotation.subtitle = [NSString stringWithFormat:@"%.1f公里",distance/1000];
        }else{
            annotation.subtitle = [NSString stringWithFormat:@"%d米",[@(distance) intValue]];
        }
        
        [_mapView addAnnotation:annotation];
        [_drawedBusAnnotations addObject:annotation];
    }
    
}

- (void)mapStatusDidChanged:(BMKMapView *)mapView{
    BMKMapStatus *status = [mapView getMapStatus];
    if (status.fLevel>14) { // 用annotation显示站点
        if (_mapView.overlays.count>0) {
            [_mapView removeOverlays:[NSArray arrayWithArray:_mapView.overlays]];
            [self addStationAnnotation];
            [self redrawBus]; // 重绘车辆图标，否则车辆图标会被站点图片挡住
        }
    }else{  // 用overlay显示站点
        if (_stationAnnotations.count>0) {
            [_mapView removeAnnotations:_stationAnnotations];
            [_stationAnnotations removeAllObjects];
            [self addStationOverlay];
            [self redrawBus];
        }
    }
}


-(void)addStationOverlay{
    count = 1;
    for (int i=0; i<_stations.count; i++) {
        JDOStationModel *station = _stations[i];
        BMKCircle *circle = [BMKCircle circleWithCenterCoordinate:CLLocationCoordinate2DMake(station.gpsY.doubleValue, station.gpsX.doubleValue) radius:220];
        if (station.isStart || station.isEnd) {
            circle.selected = [NSNumber numberWithBool:true];
        }else{
            circle.selected = [NSNumber numberWithBool:false];
        }
        [_mapView addOverlay:circle];
    }
}

- (BMKOverlayView *)mapView:(BMKMapView *)mapView viewForOverlay:(id <BMKOverlay>)overlay
{
    BMKCircleView* circleView = [[BMKCircleView alloc] initWithOverlay:overlay];
    BMKCircle *circle = (BMKCircle *)overlay;
    circleView.fillColor = [circle.selected boolValue]?[UIColor colorWithRed:55/255.0f green:170/255.0f blue:50/255.0f alpha:1.0f]:[UIColor colorWithRed:255/255.0f green:180/255.0f blue:0 alpha:1.0f];
    circleView.strokeColor = [UIColor colorWithHex:@"FEFEFE"];
    circleView.lineWidth = 1.0f;
    
    return circleView;
}

-(void)addStationAnnotation{
    [_stationAnnotations removeAllObjects];
    for (int i=0; i<_stations.count; i++) {
        JDOStationModel *station = _stations[i];
        JDOStationAnnotation *annotation = [[JDOStationAnnotation alloc] init];
        annotation.coordinate = CLLocationCoordinate2DMake(station.gpsY.doubleValue, station.gpsX.doubleValue);
        annotation.title = station.name;
        annotation.station = station;
        annotation.index = i+1;
        [_mapView addAnnotation:annotation];
        [_stationAnnotations addObject:annotation];
    }
}

- (BMKAnnotationView *)mapView:(BMKMapView *)mapView viewForAnnotation:(id <BMKAnnotation>)annotation{
    BMKAnnotationView *annotationView;
    if ([annotation isKindOfClass:[JDOStationAnnotation class]]) {
        static NSString *AnnotationViewID = @"stationAnnotation";
        annotationView = [mapView dequeueReusableAnnotationViewWithIdentifier:AnnotationViewID];
        if (!annotationView) {
            annotationView = [[BMKAnnotationView alloc] initWithAnnotation:annotation reuseIdentifier:AnnotationViewID];
            UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
            label.textAlignment = NSTextAlignmentCenter;
            label.textColor = [UIColor whiteColor];
            label.font = [UIFont systemFontOfSize:11];
            label.tag = 1001;
            [annotationView addSubview:label];
        }else{
            annotationView.annotation = annotation;
        }
        JDOStationAnnotation *sa = (JDOStationAnnotation *)annotation;
        UILabel *numLabel = (UILabel *)[annotationView viewWithTag:1001];
        numLabel.text = [NSString stringWithFormat:@"%d",sa.index];
        [numLabel sizeToFit];
        numLabel.frame = CGRectMake((18-CGRectGetWidth(numLabel.bounds))/2, (18-CGRectGetHeight(numLabel.bounds))/2, CGRectGetWidth(numLabel.bounds), CGRectGetHeight(numLabel.bounds));
        
        if (sa.station.isStart) {
            annotationView.image = [UIImage imageNamed:@"公交未选中"];
        }else if(sa.station.isEnd){
            annotationView.image = [UIImage imageNamed:@"公交未选中"];
        }else{
            annotationView.image = [UIImage imageNamed:@"公交选中"];
        }
    }else{
        static NSString *AnnotationViewID = @"busAnnotation";
        annotationView = [mapView dequeueReusableAnnotationViewWithIdentifier:AnnotationViewID];
        if (!annotationView) {
            annotationView = [[BMKAnnotationView alloc] initWithAnnotation:annotation reuseIdentifier:AnnotationViewID];
        }else{
            annotationView.annotation = annotation;
        }
        annotationView.image = [UIImage imageNamed:@"公交不透明"];
    }
    
    annotationView.draggable = false;
    return annotationView;
}

- (void)mapView:(BMKMapView *)mapView didSelectAnnotationView:(BMKAnnotationView *)view{
    NSLog(@"selected:%@",view.annotation.title);
}

- (void)mapView:(BMKMapView *)mapView didDeselectAnnotationView:(BMKAnnotationView *)view{
    NSLog(@"unselected:%@",view.annotation.title);
}

- (void)didReceiveMemoryWarning {
    [super didReceiveMemoryWarning];
}


@end
