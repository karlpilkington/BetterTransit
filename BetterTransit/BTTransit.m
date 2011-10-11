//
//  BTTransit.m
//  BetterTransit
//
//  Created by Yaogang Lian on 10/16/09.
//  Copyright 2009 Happen Next. All rights reserved.
//

#import "BTTransit.h"
#import "BTStopList.h"
#import "BTAppSettings.h"


@implementation BTTransit

@synthesize routes, routesDict, routesToDisplay;
@synthesize stops, stopsDict, tiles, nearbyStops, favoriteStops;
@synthesize db;


#pragma mark -
#pragma mark Initialization

- (id)init
{
    self = [super init];
	if (self) {
		routes = [[NSMutableArray alloc] initWithCapacity:NUM_ROUTES];
		routesDict = [[NSMutableDictionary alloc] initWithCapacity:NUM_ROUTES];
		routesToDisplay = nil;
		stops = [[NSMutableArray alloc] initWithCapacity:NUM_STOPS];
		stopsDict = [[NSMutableDictionary alloc] initWithCapacity:NUM_STOPS];
		
#if NUM_TILES > 1
		tiles = [[NSMutableArray alloc] initWithCapacity:NUM_TILES];
		for (int i=0; i<NUM_TILES; i++) {
			NSMutableArray *tile = [[NSMutableArray alloc] initWithCapacity:20];
			[tiles addObject:tile];
			[tile release];
		}
#else
		tiles = nil;
#endif
			
		nearbyStops = [[NSMutableArray alloc] init];
		favoriteStops = [[NSMutableArray alloc] init];
		
		[self loadData];
		
		// Observe notifications
		[[NSNotificationCenter defaultCenter] addObserver:self 
												 selector:@selector(didUpdateToLocation:)
													 name:kDidUpdateToLocationNotification
												   object:nil];
	}
	return self;
}

- (void)loadData
{
	// Load data from database
	NSString *path = [[NSBundle mainBundle] pathForResource:MAIN_DB ofType:@"db"];
	self.db = [FMDatabase databaseWithPath:path];
	if (![db open]) {
		NSLog(@"Could not open db.");
	}
	
	[self loadRoutesFromDB];
	[self loadRoutesToDisplayFromPlist:@"routesToDisplay"];
	[self loadScheduleForRoutes];
	[self loadStopsFromDB];
	
    //TODO: [self loadFavoriteStops];
}

- (void)loadRoutesFromDB
{	
	FMResultSet *rs = [db executeQuery:@"select * from routes"];
	while ([rs next]) {
		BTRoute *route = [[BTRoute alloc] init];
		route.routeId = [rs stringForColumn:@"route_id"];
		route.agencyId = [rs stringForColumn:@"agency_id"];
        route.shortName = [rs stringForColumn:@"route_short_name"];
		route.longName = [rs stringForColumn:@"route_long_name"];
		[self.routes addObject:route];
		[self.routesDict setObject:route forKey:route.shortName];
		[route release];
	}
	[rs close];
}

- (void)loadStopsFromDB
{
	FMResultSet *rs = [db executeQuery:@"select * from stops"];
	while ([rs next]) {
		BTStop *stop = [[BTStop alloc] init];
		stop.stopId = [rs stringForColumn:@"stop_id"];
        stop.stopCode = [rs stringForColumn:@"stop_code"];
        stop.stopName = [rs stringForColumn:@"stop_name"];
        stop.latitude = [rs doubleForColumn:@"stop_lat"];
        stop.longitude = [rs doubleForColumn:@"stop_lon"];
		[self.stops addObject:stop];
		[self.stopsDict setObject:stop forKey:stop.stopCode];
		
#if NUM_TILES > 1
		stop.tileNumber = [rs intForColumn:@"tile"];
		NSMutableArray *tile = [tiles objectAtIndex:stop.tileNumber];
		[tile addObject:stop];
#endif
		[stop release];
	}
	[rs close];
}

- (void)loadRoutesToDisplayFromPlist:(NSString *)fileName
{
	NSString *path = [[NSBundle mainBundle] pathForResource:fileName ofType:@"plist"];
	self.routesToDisplay = [[[NSDictionary alloc] initWithContentsOfFile:path] autorelease];
}

- (void)loadStopListsForRoute:(BTRoute *)route
{
	if (route.stopLists == nil) {
		route.stopLists = [NSMutableArray arrayWithCapacity:2];
	}
	
	NSArray *items = [route.subroutes componentsSeparatedByString:@","];
	for (int i=0; i<[items count]; i++) {
		BTStopList *stopList = [[BTStopList alloc] init];
		stopList.route = route;
		stopList.listId = [items objectAtIndex:i]; // "-", "1", "2", ...
		[route.stopLists addObject:stopList];
		[stopList release];
	}
	
	for (BTStopList *stopList in route.stopLists) {
		FMResultSet *rs = [db executeQuery:@"select * from stages where route_id = ? and subroute = ? order by order_id ASC",
						   route.routeId, stopList.listId];
		NSUInteger counter = 0;
		while ([rs next]) {
			if (counter == 0) {
				stopList.name = [rs stringForColumn:@"bound"];
				stopList.detail = [rs stringForColumn:@"dest"];
			}
			NSString *stopId = [rs stringForColumn:@"stop_id"];
			BTStop *stop = [self stopWithCode:stopId]; // TODO
			[stopList.stops addObject:stop];
			counter++;
		}
		[rs close];
	}
}

- (void)loadScheduleForRoutes
{
	// implement this method in subclass if necessary
}

- (void)loadFavoriteStops
{	
	NSUserDefaults *prefs = [NSUserDefaults standardUserDefaults];
	NSArray *p = [prefs objectForKey:@"favorites"];
    
	if (p != nil) {
		for (NSString *stopCode in p) {
			BTStop *stop = [self stopWithCode:stopCode];
			stop.favorite = YES;
			[self.favoriteStops addObject:stop];
		}
	}
}

- (BTRoute *)routeWithShortName:(NSString *)shortName
{
    return [self.routesDict objectForKey:shortName];
}

- (BTStop *)stopWithCode:(NSString *)stopCode
{
    return [self.stopsDict objectForKey:stopCode];
}

- (NSArray *)routeShortNamesAtStop:(BTStop *)s
{
	NSMutableDictionary *dict = [NSMutableDictionary dictionaryWithCapacity:10];
	
	NSString *stopId = s.stopId;
	FMResultSet *rs = [self.db executeQuery:@"select * from stages where stop_id = ? order by route_id ASC",
					   stopId];
	
	NSUInteger counter = 0;
	while ([rs next]) {
		NSString *routeId = [rs stringForColumn:@"route_id"];
		[dict setObject:[NSNumber numberWithInt:counter] forKey:routeId];
		counter++;
	}
	
	return [[dict allKeys] sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
}

- (void)updateNearbyStops
{
	[self.nearbyStops removeAllObjects];
	
	int maxNumberOfNearbyStops;
	if ([[BTAppSettings maxNumNearbyStops] isEqualToString:@"No Limit"]) {
		maxNumberOfNearbyStops = [self.stops count];
	} else {
		maxNumberOfNearbyStops = [[BTAppSettings maxNumNearbyStops] intValue];
	}
	
	double radius;
	if ([[BTAppSettings nearbyRadius] isEqualToString:@"No Limit"]) {
		radius = 50000000;
	} else {
#ifdef METRIC_UNIT
		NSRange rangeOfKm = [[BTAppSettings nearbyRadius] rangeOfString:@" km"];
		radius = [[[BTAppSettings nearbyRadius] substringToIndex:rangeOfKm.location] doubleValue]*1000;
#endif

#ifdef ENGLISH_UNIT
		NSRange rangeOfMi = [[BTAppSettings nearbyRadius] rangeOfString:@" mi"];
		radius = [[[BTAppSettings nearbyRadius] substringToIndex:rangeOfMi.location] doubleValue]*1609.344;
#endif
	}
	
	int count = 0;
	for (int i=0; i<[self.stops count]; i++) {
		BTStop *stop = [self.stops objectAtIndex:i];
		if (stop.distance > -1 && stop.distance < radius) {
			[self.nearbyStops addObject:stop];
			count++;
			if (count >= maxNumberOfNearbyStops) break;
		}
	}
}

- (void)sortStops:(NSMutableArray *)ss ByDistanceFrom:(CLLocation *)location
{
	BTStop *stop;
	CLLocation *stopLocation;
	for (stop in ss) {
		stopLocation = [[CLLocation alloc] initWithLatitude:stop.latitude longitude:stop.longitude];
		stop.distance = [stopLocation getDistanceFrom:location]; // in meters
		[stopLocation release];
	}
	
	NSSortDescriptor *sort = [[NSSortDescriptor alloc] initWithKey:@"distance" ascending:YES];
	[ss sortUsingDescriptors:[NSArray arrayWithObject:sort]];
	[sort release];
}

- (void)dealloc
{
	[routes release], routes = nil;
	[routesDict release], routesDict = nil;
	[routesToDisplay release], routesToDisplay = nil;
	[stops release], stops = nil;
	[stopsDict release], stopsDict = nil;
	[tiles release], tiles = nil;
	[nearbyStops release], nearbyStops = nil;
	[favoriteStops release], favoriteStops = nil;
	[db close], [db release], db = nil;
	
	[[NSNotificationCenter defaultCenter] removeObserver:self];
	[super dealloc];
}


#pragma mark -
#pragma mark Location updates

- (void)didUpdateToLocation:(NSNotification *)notification
{
	CLLocation *newLocation = [[notification userInfo] objectForKey:@"location"];
	[self sortStops:self.stops ByDistanceFrom:newLocation];
	[self updateNearbyStops];
}

@end
