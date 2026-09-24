// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'db.dart';

// ignore_for_file: type=lint
class $EventRowsTable extends EventRows
    with TableInfo<$EventRowsTable, EventRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $EventRowsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _eventIdMeta = const VerificationMeta(
    'eventId',
  );
  @override
  late final GeneratedColumn<String> eventId = GeneratedColumn<String>(
    'event_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _deviceIdMeta = const VerificationMeta(
    'deviceId',
  );
  @override
  late final GeneratedColumn<String> deviceId = GeneratedColumn<String>(
    'device_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _sessionIdMeta = const VerificationMeta(
    'sessionId',
  );
  @override
  late final GeneratedColumn<String> sessionId = GeneratedColumn<String>(
    'session_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _bookIdMeta = const VerificationMeta('bookId');
  @override
  late final GeneratedColumn<String> bookId = GeneratedColumn<String>(
    'book_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _manifestIdMeta = const VerificationMeta(
    'manifestId',
  );
  @override
  late final GeneratedColumn<String> manifestId = GeneratedColumn<String>(
    'manifest_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _typeMeta = const VerificationMeta('type');
  @override
  late final GeneratedColumn<String> type = GeneratedColumn<String>(
    'type',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _fileHashMeta = const VerificationMeta(
    'fileHash',
  );
  @override
  late final GeneratedColumn<String> fileHash = GeneratedColumn<String>(
    'file_hash',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _offsetMsMeta = const VerificationMeta(
    'offsetMs',
  );
  @override
  late final GeneratedColumn<int> offsetMs = GeneratedColumn<int>(
    'offset_ms',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _hlcPtMeta = const VerificationMeta('hlcPt');
  @override
  late final GeneratedColumn<int> hlcPt = GeneratedColumn<int>(
    'hlc_pt',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _hlcCMeta = const VerificationMeta('hlcC');
  @override
  late final GeneratedColumn<int> hlcC = GeneratedColumn<int>(
    'hlc_c',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _wallMsMeta = const VerificationMeta('wallMs');
  @override
  late final GeneratedColumn<int> wallMs = GeneratedColumn<int>(
    'wall_ms',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _tzMinMeta = const VerificationMeta('tzMin');
  @override
  late final GeneratedColumn<int> tzMin = GeneratedColumn<int>(
    'tz_min',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _sourceMeta = const VerificationMeta('source');
  @override
  late final GeneratedColumn<String> source = GeneratedColumn<String>(
    'source',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _dataJsonMeta = const VerificationMeta(
    'dataJson',
  );
  @override
  late final GeneratedColumn<String> dataJson = GeneratedColumn<String>(
    'data_json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('{}'),
  );
  static const VerificationMeta _syncedMeta = const VerificationMeta('synced');
  @override
  late final GeneratedColumn<bool> synced = GeneratedColumn<bool>(
    'synced',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("synced" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  @override
  List<GeneratedColumn> get $columns => [
    eventId,
    deviceId,
    sessionId,
    bookId,
    manifestId,
    type,
    fileHash,
    offsetMs,
    hlcPt,
    hlcC,
    wallMs,
    tzMin,
    source,
    dataJson,
    synced,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'event_rows';
  @override
  VerificationContext validateIntegrity(
    Insertable<EventRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('event_id')) {
      context.handle(
        _eventIdMeta,
        eventId.isAcceptableOrUnknown(data['event_id']!, _eventIdMeta),
      );
    } else if (isInserting) {
      context.missing(_eventIdMeta);
    }
    if (data.containsKey('device_id')) {
      context.handle(
        _deviceIdMeta,
        deviceId.isAcceptableOrUnknown(data['device_id']!, _deviceIdMeta),
      );
    } else if (isInserting) {
      context.missing(_deviceIdMeta);
    }
    if (data.containsKey('session_id')) {
      context.handle(
        _sessionIdMeta,
        sessionId.isAcceptableOrUnknown(data['session_id']!, _sessionIdMeta),
      );
    } else if (isInserting) {
      context.missing(_sessionIdMeta);
    }
    if (data.containsKey('book_id')) {
      context.handle(
        _bookIdMeta,
        bookId.isAcceptableOrUnknown(data['book_id']!, _bookIdMeta),
      );
    } else if (isInserting) {
      context.missing(_bookIdMeta);
    }
    if (data.containsKey('manifest_id')) {
      context.handle(
        _manifestIdMeta,
        manifestId.isAcceptableOrUnknown(data['manifest_id']!, _manifestIdMeta),
      );
    } else if (isInserting) {
      context.missing(_manifestIdMeta);
    }
    if (data.containsKey('type')) {
      context.handle(
        _typeMeta,
        type.isAcceptableOrUnknown(data['type']!, _typeMeta),
      );
    } else if (isInserting) {
      context.missing(_typeMeta);
    }
    if (data.containsKey('file_hash')) {
      context.handle(
        _fileHashMeta,
        fileHash.isAcceptableOrUnknown(data['file_hash']!, _fileHashMeta),
      );
    } else if (isInserting) {
      context.missing(_fileHashMeta);
    }
    if (data.containsKey('offset_ms')) {
      context.handle(
        _offsetMsMeta,
        offsetMs.isAcceptableOrUnknown(data['offset_ms']!, _offsetMsMeta),
      );
    } else if (isInserting) {
      context.missing(_offsetMsMeta);
    }
    if (data.containsKey('hlc_pt')) {
      context.handle(
        _hlcPtMeta,
        hlcPt.isAcceptableOrUnknown(data['hlc_pt']!, _hlcPtMeta),
      );
    } else if (isInserting) {
      context.missing(_hlcPtMeta);
    }
    if (data.containsKey('hlc_c')) {
      context.handle(
        _hlcCMeta,
        hlcC.isAcceptableOrUnknown(data['hlc_c']!, _hlcCMeta),
      );
    } else if (isInserting) {
      context.missing(_hlcCMeta);
    }
    if (data.containsKey('wall_ms')) {
      context.handle(
        _wallMsMeta,
        wallMs.isAcceptableOrUnknown(data['wall_ms']!, _wallMsMeta),
      );
    } else if (isInserting) {
      context.missing(_wallMsMeta);
    }
    if (data.containsKey('tz_min')) {
      context.handle(
        _tzMinMeta,
        tzMin.isAcceptableOrUnknown(data['tz_min']!, _tzMinMeta),
      );
    } else if (isInserting) {
      context.missing(_tzMinMeta);
    }
    if (data.containsKey('source')) {
      context.handle(
        _sourceMeta,
        source.isAcceptableOrUnknown(data['source']!, _sourceMeta),
      );
    } else if (isInserting) {
      context.missing(_sourceMeta);
    }
    if (data.containsKey('data_json')) {
      context.handle(
        _dataJsonMeta,
        dataJson.isAcceptableOrUnknown(data['data_json']!, _dataJsonMeta),
      );
    }
    if (data.containsKey('synced')) {
      context.handle(
        _syncedMeta,
        synced.isAcceptableOrUnknown(data['synced']!, _syncedMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {eventId};
  @override
  EventRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return EventRow(
      eventId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}event_id'],
      )!,
      deviceId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}device_id'],
      )!,
      sessionId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}session_id'],
      )!,
      bookId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}book_id'],
      )!,
      manifestId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}manifest_id'],
      )!,
      type: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}type'],
      )!,
      fileHash: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}file_hash'],
      )!,
      offsetMs: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}offset_ms'],
      )!,
      hlcPt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}hlc_pt'],
      )!,
      hlcC: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}hlc_c'],
      )!,
      wallMs: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}wall_ms'],
      )!,
      tzMin: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}tz_min'],
      )!,
      source: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}source'],
      )!,
      dataJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}data_json'],
      )!,
      synced: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}synced'],
      )!,
    );
  }

  @override
  $EventRowsTable createAlias(String alias) {
    return $EventRowsTable(attachedDatabase, alias);
  }
}

class EventRow extends DataClass implements Insertable<EventRow> {
  final String eventId;
  final String deviceId;
  final String sessionId;
  final String bookId;
  final String manifestId;
  final String type;
  final String fileHash;
  final int offsetMs;
  final int hlcPt;
  final int hlcC;
  final int wallMs;
  final int tzMin;
  final String source;
  final String dataJson;

  /// Set once the server has accepted this event (section 6 push). Lets the
  /// sync client find only the rows it still needs to push.
  final bool synced;
  const EventRow({
    required this.eventId,
    required this.deviceId,
    required this.sessionId,
    required this.bookId,
    required this.manifestId,
    required this.type,
    required this.fileHash,
    required this.offsetMs,
    required this.hlcPt,
    required this.hlcC,
    required this.wallMs,
    required this.tzMin,
    required this.source,
    required this.dataJson,
    required this.synced,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['event_id'] = Variable<String>(eventId);
    map['device_id'] = Variable<String>(deviceId);
    map['session_id'] = Variable<String>(sessionId);
    map['book_id'] = Variable<String>(bookId);
    map['manifest_id'] = Variable<String>(manifestId);
    map['type'] = Variable<String>(type);
    map['file_hash'] = Variable<String>(fileHash);
    map['offset_ms'] = Variable<int>(offsetMs);
    map['hlc_pt'] = Variable<int>(hlcPt);
    map['hlc_c'] = Variable<int>(hlcC);
    map['wall_ms'] = Variable<int>(wallMs);
    map['tz_min'] = Variable<int>(tzMin);
    map['source'] = Variable<String>(source);
    map['data_json'] = Variable<String>(dataJson);
    map['synced'] = Variable<bool>(synced);
    return map;
  }

  EventRowsCompanion toCompanion(bool nullToAbsent) {
    return EventRowsCompanion(
      eventId: Value(eventId),
      deviceId: Value(deviceId),
      sessionId: Value(sessionId),
      bookId: Value(bookId),
      manifestId: Value(manifestId),
      type: Value(type),
      fileHash: Value(fileHash),
      offsetMs: Value(offsetMs),
      hlcPt: Value(hlcPt),
      hlcC: Value(hlcC),
      wallMs: Value(wallMs),
      tzMin: Value(tzMin),
      source: Value(source),
      dataJson: Value(dataJson),
      synced: Value(synced),
    );
  }

  factory EventRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return EventRow(
      eventId: serializer.fromJson<String>(json['eventId']),
      deviceId: serializer.fromJson<String>(json['deviceId']),
      sessionId: serializer.fromJson<String>(json['sessionId']),
      bookId: serializer.fromJson<String>(json['bookId']),
      manifestId: serializer.fromJson<String>(json['manifestId']),
      type: serializer.fromJson<String>(json['type']),
      fileHash: serializer.fromJson<String>(json['fileHash']),
      offsetMs: serializer.fromJson<int>(json['offsetMs']),
      hlcPt: serializer.fromJson<int>(json['hlcPt']),
      hlcC: serializer.fromJson<int>(json['hlcC']),
      wallMs: serializer.fromJson<int>(json['wallMs']),
      tzMin: serializer.fromJson<int>(json['tzMin']),
      source: serializer.fromJson<String>(json['source']),
      dataJson: serializer.fromJson<String>(json['dataJson']),
      synced: serializer.fromJson<bool>(json['synced']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'eventId': serializer.toJson<String>(eventId),
      'deviceId': serializer.toJson<String>(deviceId),
      'sessionId': serializer.toJson<String>(sessionId),
      'bookId': serializer.toJson<String>(bookId),
      'manifestId': serializer.toJson<String>(manifestId),
      'type': serializer.toJson<String>(type),
      'fileHash': serializer.toJson<String>(fileHash),
      'offsetMs': serializer.toJson<int>(offsetMs),
      'hlcPt': serializer.toJson<int>(hlcPt),
      'hlcC': serializer.toJson<int>(hlcC),
      'wallMs': serializer.toJson<int>(wallMs),
      'tzMin': serializer.toJson<int>(tzMin),
      'source': serializer.toJson<String>(source),
      'dataJson': serializer.toJson<String>(dataJson),
      'synced': serializer.toJson<bool>(synced),
    };
  }

  EventRow copyWith({
    String? eventId,
    String? deviceId,
    String? sessionId,
    String? bookId,
    String? manifestId,
    String? type,
    String? fileHash,
    int? offsetMs,
    int? hlcPt,
    int? hlcC,
    int? wallMs,
    int? tzMin,
    String? source,
    String? dataJson,
    bool? synced,
  }) => EventRow(
    eventId: eventId ?? this.eventId,
    deviceId: deviceId ?? this.deviceId,
    sessionId: sessionId ?? this.sessionId,
    bookId: bookId ?? this.bookId,
    manifestId: manifestId ?? this.manifestId,
    type: type ?? this.type,
    fileHash: fileHash ?? this.fileHash,
    offsetMs: offsetMs ?? this.offsetMs,
    hlcPt: hlcPt ?? this.hlcPt,
    hlcC: hlcC ?? this.hlcC,
    wallMs: wallMs ?? this.wallMs,
    tzMin: tzMin ?? this.tzMin,
    source: source ?? this.source,
    dataJson: dataJson ?? this.dataJson,
    synced: synced ?? this.synced,
  );
  EventRow copyWithCompanion(EventRowsCompanion data) {
    return EventRow(
      eventId: data.eventId.present ? data.eventId.value : this.eventId,
      deviceId: data.deviceId.present ? data.deviceId.value : this.deviceId,
      sessionId: data.sessionId.present ? data.sessionId.value : this.sessionId,
      bookId: data.bookId.present ? data.bookId.value : this.bookId,
      manifestId: data.manifestId.present
          ? data.manifestId.value
          : this.manifestId,
      type: data.type.present ? data.type.value : this.type,
      fileHash: data.fileHash.present ? data.fileHash.value : this.fileHash,
      offsetMs: data.offsetMs.present ? data.offsetMs.value : this.offsetMs,
      hlcPt: data.hlcPt.present ? data.hlcPt.value : this.hlcPt,
      hlcC: data.hlcC.present ? data.hlcC.value : this.hlcC,
      wallMs: data.wallMs.present ? data.wallMs.value : this.wallMs,
      tzMin: data.tzMin.present ? data.tzMin.value : this.tzMin,
      source: data.source.present ? data.source.value : this.source,
      dataJson: data.dataJson.present ? data.dataJson.value : this.dataJson,
      synced: data.synced.present ? data.synced.value : this.synced,
    );
  }

  @override
  String toString() {
    return (StringBuffer('EventRow(')
          ..write('eventId: $eventId, ')
          ..write('deviceId: $deviceId, ')
          ..write('sessionId: $sessionId, ')
          ..write('bookId: $bookId, ')
          ..write('manifestId: $manifestId, ')
          ..write('type: $type, ')
          ..write('fileHash: $fileHash, ')
          ..write('offsetMs: $offsetMs, ')
          ..write('hlcPt: $hlcPt, ')
          ..write('hlcC: $hlcC, ')
          ..write('wallMs: $wallMs, ')
          ..write('tzMin: $tzMin, ')
          ..write('source: $source, ')
          ..write('dataJson: $dataJson, ')
          ..write('synced: $synced')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    eventId,
    deviceId,
    sessionId,
    bookId,
    manifestId,
    type,
    fileHash,
    offsetMs,
    hlcPt,
    hlcC,
    wallMs,
    tzMin,
    source,
    dataJson,
    synced,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is EventRow &&
          other.eventId == this.eventId &&
          other.deviceId == this.deviceId &&
          other.sessionId == this.sessionId &&
          other.bookId == this.bookId &&
          other.manifestId == this.manifestId &&
          other.type == this.type &&
          other.fileHash == this.fileHash &&
          other.offsetMs == this.offsetMs &&
          other.hlcPt == this.hlcPt &&
          other.hlcC == this.hlcC &&
          other.wallMs == this.wallMs &&
          other.tzMin == this.tzMin &&
          other.source == this.source &&
          other.dataJson == this.dataJson &&
          other.synced == this.synced);
}

class EventRowsCompanion extends UpdateCompanion<EventRow> {
  final Value<String> eventId;
  final Value<String> deviceId;
  final Value<String> sessionId;
  final Value<String> bookId;
  final Value<String> manifestId;
  final Value<String> type;
  final Value<String> fileHash;
  final Value<int> offsetMs;
  final Value<int> hlcPt;
  final Value<int> hlcC;
  final Value<int> wallMs;
  final Value<int> tzMin;
  final Value<String> source;
  final Value<String> dataJson;
  final Value<bool> synced;
  final Value<int> rowid;
  const EventRowsCompanion({
    this.eventId = const Value.absent(),
    this.deviceId = const Value.absent(),
    this.sessionId = const Value.absent(),
    this.bookId = const Value.absent(),
    this.manifestId = const Value.absent(),
    this.type = const Value.absent(),
    this.fileHash = const Value.absent(),
    this.offsetMs = const Value.absent(),
    this.hlcPt = const Value.absent(),
    this.hlcC = const Value.absent(),
    this.wallMs = const Value.absent(),
    this.tzMin = const Value.absent(),
    this.source = const Value.absent(),
    this.dataJson = const Value.absent(),
    this.synced = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  EventRowsCompanion.insert({
    required String eventId,
    required String deviceId,
    required String sessionId,
    required String bookId,
    required String manifestId,
    required String type,
    required String fileHash,
    required int offsetMs,
    required int hlcPt,
    required int hlcC,
    required int wallMs,
    required int tzMin,
    required String source,
    this.dataJson = const Value.absent(),
    this.synced = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : eventId = Value(eventId),
       deviceId = Value(deviceId),
       sessionId = Value(sessionId),
       bookId = Value(bookId),
       manifestId = Value(manifestId),
       type = Value(type),
       fileHash = Value(fileHash),
       offsetMs = Value(offsetMs),
       hlcPt = Value(hlcPt),
       hlcC = Value(hlcC),
       wallMs = Value(wallMs),
       tzMin = Value(tzMin),
       source = Value(source);
  static Insertable<EventRow> custom({
    Expression<String>? eventId,
    Expression<String>? deviceId,
    Expression<String>? sessionId,
    Expression<String>? bookId,
    Expression<String>? manifestId,
    Expression<String>? type,
    Expression<String>? fileHash,
    Expression<int>? offsetMs,
    Expression<int>? hlcPt,
    Expression<int>? hlcC,
    Expression<int>? wallMs,
    Expression<int>? tzMin,
    Expression<String>? source,
    Expression<String>? dataJson,
    Expression<bool>? synced,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (eventId != null) 'event_id': eventId,
      if (deviceId != null) 'device_id': deviceId,
      if (sessionId != null) 'session_id': sessionId,
      if (bookId != null) 'book_id': bookId,
      if (manifestId != null) 'manifest_id': manifestId,
      if (type != null) 'type': type,
      if (fileHash != null) 'file_hash': fileHash,
      if (offsetMs != null) 'offset_ms': offsetMs,
      if (hlcPt != null) 'hlc_pt': hlcPt,
      if (hlcC != null) 'hlc_c': hlcC,
      if (wallMs != null) 'wall_ms': wallMs,
      if (tzMin != null) 'tz_min': tzMin,
      if (source != null) 'source': source,
      if (dataJson != null) 'data_json': dataJson,
      if (synced != null) 'synced': synced,
      if (rowid != null) 'rowid': rowid,
    });
  }

  EventRowsCompanion copyWith({
    Value<String>? eventId,
    Value<String>? deviceId,
    Value<String>? sessionId,
    Value<String>? bookId,
    Value<String>? manifestId,
    Value<String>? type,
    Value<String>? fileHash,
    Value<int>? offsetMs,
    Value<int>? hlcPt,
    Value<int>? hlcC,
    Value<int>? wallMs,
    Value<int>? tzMin,
    Value<String>? source,
    Value<String>? dataJson,
    Value<bool>? synced,
    Value<int>? rowid,
  }) {
    return EventRowsCompanion(
      eventId: eventId ?? this.eventId,
      deviceId: deviceId ?? this.deviceId,
      sessionId: sessionId ?? this.sessionId,
      bookId: bookId ?? this.bookId,
      manifestId: manifestId ?? this.manifestId,
      type: type ?? this.type,
      fileHash: fileHash ?? this.fileHash,
      offsetMs: offsetMs ?? this.offsetMs,
      hlcPt: hlcPt ?? this.hlcPt,
      hlcC: hlcC ?? this.hlcC,
      wallMs: wallMs ?? this.wallMs,
      tzMin: tzMin ?? this.tzMin,
      source: source ?? this.source,
      dataJson: dataJson ?? this.dataJson,
      synced: synced ?? this.synced,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (eventId.present) {
      map['event_id'] = Variable<String>(eventId.value);
    }
    if (deviceId.present) {
      map['device_id'] = Variable<String>(deviceId.value);
    }
    if (sessionId.present) {
      map['session_id'] = Variable<String>(sessionId.value);
    }
    if (bookId.present) {
      map['book_id'] = Variable<String>(bookId.value);
    }
    if (manifestId.present) {
      map['manifest_id'] = Variable<String>(manifestId.value);
    }
    if (type.present) {
      map['type'] = Variable<String>(type.value);
    }
    if (fileHash.present) {
      map['file_hash'] = Variable<String>(fileHash.value);
    }
    if (offsetMs.present) {
      map['offset_ms'] = Variable<int>(offsetMs.value);
    }
    if (hlcPt.present) {
      map['hlc_pt'] = Variable<int>(hlcPt.value);
    }
    if (hlcC.present) {
      map['hlc_c'] = Variable<int>(hlcC.value);
    }
    if (wallMs.present) {
      map['wall_ms'] = Variable<int>(wallMs.value);
    }
    if (tzMin.present) {
      map['tz_min'] = Variable<int>(tzMin.value);
    }
    if (source.present) {
      map['source'] = Variable<String>(source.value);
    }
    if (dataJson.present) {
      map['data_json'] = Variable<String>(dataJson.value);
    }
    if (synced.present) {
      map['synced'] = Variable<bool>(synced.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('EventRowsCompanion(')
          ..write('eventId: $eventId, ')
          ..write('deviceId: $deviceId, ')
          ..write('sessionId: $sessionId, ')
          ..write('bookId: $bookId, ')
          ..write('manifestId: $manifestId, ')
          ..write('type: $type, ')
          ..write('fileHash: $fileHash, ')
          ..write('offsetMs: $offsetMs, ')
          ..write('hlcPt: $hlcPt, ')
          ..write('hlcC: $hlcC, ')
          ..write('wallMs: $wallMs, ')
          ..write('tzMin: $tzMin, ')
          ..write('source: $source, ')
          ..write('dataJson: $dataJson, ')
          ..write('synced: $synced, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $SyncStateTable extends SyncState
    with TableInfo<$SyncStateTable, SyncStateData> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $SyncStateTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _sinceSeqMeta = const VerificationMeta(
    'sinceSeq',
  );
  @override
  late final GeneratedColumn<int> sinceSeq = GeneratedColumn<int>(
    'since_seq',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  @override
  List<GeneratedColumn> get $columns => [id, sinceSeq];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'sync_state';
  @override
  VerificationContext validateIntegrity(
    Insertable<SyncStateData> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('since_seq')) {
      context.handle(
        _sinceSeqMeta,
        sinceSeq.isAcceptableOrUnknown(data['since_seq']!, _sinceSeqMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  SyncStateData map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return SyncStateData(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}id'],
      )!,
      sinceSeq: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}since_seq'],
      )!,
    );
  }

  @override
  $SyncStateTable createAlias(String alias) {
    return $SyncStateTable(attachedDatabase, alias);
  }
}

class SyncStateData extends DataClass implements Insertable<SyncStateData> {
  final int id;
  final int sinceSeq;
  const SyncStateData({required this.id, required this.sinceSeq});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['since_seq'] = Variable<int>(sinceSeq);
    return map;
  }

  SyncStateCompanion toCompanion(bool nullToAbsent) {
    return SyncStateCompanion(id: Value(id), sinceSeq: Value(sinceSeq));
  }

  factory SyncStateData.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return SyncStateData(
      id: serializer.fromJson<int>(json['id']),
      sinceSeq: serializer.fromJson<int>(json['sinceSeq']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'sinceSeq': serializer.toJson<int>(sinceSeq),
    };
  }

  SyncStateData copyWith({int? id, int? sinceSeq}) =>
      SyncStateData(id: id ?? this.id, sinceSeq: sinceSeq ?? this.sinceSeq);
  SyncStateData copyWithCompanion(SyncStateCompanion data) {
    return SyncStateData(
      id: data.id.present ? data.id.value : this.id,
      sinceSeq: data.sinceSeq.present ? data.sinceSeq.value : this.sinceSeq,
    );
  }

  @override
  String toString() {
    return (StringBuffer('SyncStateData(')
          ..write('id: $id, ')
          ..write('sinceSeq: $sinceSeq')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, sinceSeq);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SyncStateData &&
          other.id == this.id &&
          other.sinceSeq == this.sinceSeq);
}

class SyncStateCompanion extends UpdateCompanion<SyncStateData> {
  final Value<int> id;
  final Value<int> sinceSeq;
  const SyncStateCompanion({
    this.id = const Value.absent(),
    this.sinceSeq = const Value.absent(),
  });
  SyncStateCompanion.insert({
    this.id = const Value.absent(),
    this.sinceSeq = const Value.absent(),
  });
  static Insertable<SyncStateData> custom({
    Expression<int>? id,
    Expression<int>? sinceSeq,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (sinceSeq != null) 'since_seq': sinceSeq,
    });
  }

  SyncStateCompanion copyWith({Value<int>? id, Value<int>? sinceSeq}) {
    return SyncStateCompanion(
      id: id ?? this.id,
      sinceSeq: sinceSeq ?? this.sinceSeq,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (sinceSeq.present) {
      map['since_seq'] = Variable<int>(sinceSeq.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('SyncStateCompanion(')
          ..write('id: $id, ')
          ..write('sinceSeq: $sinceSeq')
          ..write(')'))
        .toString();
  }
}

class $KeyValueSettingsTable extends KeyValueSettings
    with TableInfo<$KeyValueSettingsTable, KeyValueSetting> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $KeyValueSettingsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _keyMeta = const VerificationMeta('key');
  @override
  late final GeneratedColumn<String> key = GeneratedColumn<String>(
    'key',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _valueMeta = const VerificationMeta('value');
  @override
  late final GeneratedColumn<String> value = GeneratedColumn<String>(
    'value',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [key, value];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'key_value_settings';
  @override
  VerificationContext validateIntegrity(
    Insertable<KeyValueSetting> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('key')) {
      context.handle(
        _keyMeta,
        key.isAcceptableOrUnknown(data['key']!, _keyMeta),
      );
    } else if (isInserting) {
      context.missing(_keyMeta);
    }
    if (data.containsKey('value')) {
      context.handle(
        _valueMeta,
        value.isAcceptableOrUnknown(data['value']!, _valueMeta),
      );
    } else if (isInserting) {
      context.missing(_valueMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {key};
  @override
  KeyValueSetting map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return KeyValueSetting(
      key: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}key'],
      )!,
      value: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}value'],
      )!,
    );
  }

  @override
  $KeyValueSettingsTable createAlias(String alias) {
    return $KeyValueSettingsTable(attachedDatabase, alias);
  }
}

class KeyValueSetting extends DataClass implements Insertable<KeyValueSetting> {
  final String key;
  final String value;
  const KeyValueSetting({required this.key, required this.value});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['key'] = Variable<String>(key);
    map['value'] = Variable<String>(value);
    return map;
  }

  KeyValueSettingsCompanion toCompanion(bool nullToAbsent) {
    return KeyValueSettingsCompanion(key: Value(key), value: Value(value));
  }

  factory KeyValueSetting.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return KeyValueSetting(
      key: serializer.fromJson<String>(json['key']),
      value: serializer.fromJson<String>(json['value']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'key': serializer.toJson<String>(key),
      'value': serializer.toJson<String>(value),
    };
  }

  KeyValueSetting copyWith({String? key, String? value}) =>
      KeyValueSetting(key: key ?? this.key, value: value ?? this.value);
  KeyValueSetting copyWithCompanion(KeyValueSettingsCompanion data) {
    return KeyValueSetting(
      key: data.key.present ? data.key.value : this.key,
      value: data.value.present ? data.value.value : this.value,
    );
  }

  @override
  String toString() {
    return (StringBuffer('KeyValueSetting(')
          ..write('key: $key, ')
          ..write('value: $value')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(key, value);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is KeyValueSetting &&
          other.key == this.key &&
          other.value == this.value);
}

class KeyValueSettingsCompanion extends UpdateCompanion<KeyValueSetting> {
  final Value<String> key;
  final Value<String> value;
  final Value<int> rowid;
  const KeyValueSettingsCompanion({
    this.key = const Value.absent(),
    this.value = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  KeyValueSettingsCompanion.insert({
    required String key,
    required String value,
    this.rowid = const Value.absent(),
  }) : key = Value(key),
       value = Value(value);
  static Insertable<KeyValueSetting> custom({
    Expression<String>? key,
    Expression<String>? value,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (key != null) 'key': key,
      if (value != null) 'value': value,
      if (rowid != null) 'rowid': rowid,
    });
  }

  KeyValueSettingsCompanion copyWith({
    Value<String>? key,
    Value<String>? value,
    Value<int>? rowid,
  }) {
    return KeyValueSettingsCompanion(
      key: key ?? this.key,
      value: value ?? this.value,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (key.present) {
      map['key'] = Variable<String>(key.value);
    }
    if (value.present) {
      map['value'] = Variable<String>(value.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('KeyValueSettingsCompanion(')
          ..write('key: $key, ')
          ..write('value: $value, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

abstract class _$AppDatabase extends GeneratedDatabase {
  _$AppDatabase(QueryExecutor e) : super(e);
  $AppDatabaseManager get managers => $AppDatabaseManager(this);
  late final $EventRowsTable eventRows = $EventRowsTable(this);
  late final $SyncStateTable syncState = $SyncStateTable(this);
  late final $KeyValueSettingsTable keyValueSettings = $KeyValueSettingsTable(
    this,
  );
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [
    eventRows,
    syncState,
    keyValueSettings,
  ];
}

typedef $$EventRowsTableCreateCompanionBuilder = EventRowsCompanion Function({
  required String eventId,
  required String deviceId,
  required String sessionId,
  required String bookId,
  required String manifestId,
  required String type,
  required String fileHash,
  required int offsetMs,
  required int hlcPt,
  required int hlcC,
  required int wallMs,
  required int tzMin,
  required String source,
  Value<String> dataJson,
  Value<bool> synced,
  Value<int> rowid,
});
typedef $$EventRowsTableUpdateCompanionBuilder = EventRowsCompanion Function({
  Value<String> eventId,
  Value<String> deviceId,
  Value<String> sessionId,
  Value<String> bookId,
  Value<String> manifestId,
  Value<String> type,
  Value<String> fileHash,
  Value<int> offsetMs,
  Value<int> hlcPt,
  Value<int> hlcC,
  Value<int> wallMs,
  Value<int> tzMin,
  Value<String> source,
  Value<String> dataJson,
  Value<bool> synced,
  Value<int> rowid,
});

class $$EventRowsTableFilterComposer
    extends Composer<_$AppDatabase, $EventRowsTable> {
  $$EventRowsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get eventId => $composableBuilder(
    column: $table.eventId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get deviceId => $composableBuilder(
    column: $table.deviceId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get sessionId => $composableBuilder(
    column: $table.sessionId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get bookId => $composableBuilder(
    column: $table.bookId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get manifestId => $composableBuilder(
    column: $table.manifestId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get type => $composableBuilder(
    column: $table.type,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get fileHash => $composableBuilder(
    column: $table.fileHash,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get offsetMs => $composableBuilder(
    column: $table.offsetMs,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get hlcPt => $composableBuilder(
    column: $table.hlcPt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get hlcC => $composableBuilder(
    column: $table.hlcC,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get wallMs => $composableBuilder(
    column: $table.wallMs,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get tzMin => $composableBuilder(
    column: $table.tzMin,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get source => $composableBuilder(
    column: $table.source,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get dataJson => $composableBuilder(
    column: $table.dataJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get synced => $composableBuilder(
    column: $table.synced,
    builder: (column) => ColumnFilters(column),
  );
}

class $$EventRowsTableOrderingComposer
    extends Composer<_$AppDatabase, $EventRowsTable> {
  $$EventRowsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get eventId => $composableBuilder(
    column: $table.eventId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get deviceId => $composableBuilder(
    column: $table.deviceId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get sessionId => $composableBuilder(
    column: $table.sessionId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get bookId => $composableBuilder(
    column: $table.bookId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get manifestId => $composableBuilder(
    column: $table.manifestId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get type => $composableBuilder(
    column: $table.type,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get fileHash => $composableBuilder(
    column: $table.fileHash,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get offsetMs => $composableBuilder(
    column: $table.offsetMs,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get hlcPt => $composableBuilder(
    column: $table.hlcPt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get hlcC => $composableBuilder(
    column: $table.hlcC,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get wallMs => $composableBuilder(
    column: $table.wallMs,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get tzMin => $composableBuilder(
    column: $table.tzMin,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get source => $composableBuilder(
    column: $table.source,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get dataJson => $composableBuilder(
    column: $table.dataJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get synced => $composableBuilder(
    column: $table.synced,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$EventRowsTableAnnotationComposer
    extends Composer<_$AppDatabase, $EventRowsTable> {
  $$EventRowsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get eventId =>
      $composableBuilder(column: $table.eventId, builder: (column) => column);

  GeneratedColumn<String> get deviceId =>
      $composableBuilder(column: $table.deviceId, builder: (column) => column);

  GeneratedColumn<String> get sessionId =>
      $composableBuilder(column: $table.sessionId, builder: (column) => column);

  GeneratedColumn<String> get bookId =>
      $composableBuilder(column: $table.bookId, builder: (column) => column);

  GeneratedColumn<String> get manifestId => $composableBuilder(
    column: $table.manifestId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get type =>
      $composableBuilder(column: $table.type, builder: (column) => column);

  GeneratedColumn<String> get fileHash =>
      $composableBuilder(column: $table.fileHash, builder: (column) => column);

  GeneratedColumn<int> get offsetMs =>
      $composableBuilder(column: $table.offsetMs, builder: (column) => column);

  GeneratedColumn<int> get hlcPt =>
      $composableBuilder(column: $table.hlcPt, builder: (column) => column);

  GeneratedColumn<int> get hlcC =>
      $composableBuilder(column: $table.hlcC, builder: (column) => column);

  GeneratedColumn<int> get wallMs =>
      $composableBuilder(column: $table.wallMs, builder: (column) => column);

  GeneratedColumn<int> get tzMin =>
      $composableBuilder(column: $table.tzMin, builder: (column) => column);

  GeneratedColumn<String> get source =>
      $composableBuilder(column: $table.source, builder: (column) => column);

  GeneratedColumn<String> get dataJson =>
      $composableBuilder(column: $table.dataJson, builder: (column) => column);

  GeneratedColumn<bool> get synced =>
      $composableBuilder(column: $table.synced, builder: (column) => column);
}

class $$EventRowsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $EventRowsTable,
          EventRow,
          $$EventRowsTableFilterComposer,
          $$EventRowsTableOrderingComposer,
          $$EventRowsTableAnnotationComposer,
          $$EventRowsTableCreateCompanionBuilder,
          $$EventRowsTableUpdateCompanionBuilder,
          (EventRow, BaseReferences<_$AppDatabase, $EventRowsTable, EventRow>),
          EventRow,
          PrefetchHooks Function()
        > {
  $$EventRowsTableTableManager(_$AppDatabase db, $EventRowsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$EventRowsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$EventRowsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$EventRowsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> eventId = const Value.absent(),
                Value<String> deviceId = const Value.absent(),
                Value<String> sessionId = const Value.absent(),
                Value<String> bookId = const Value.absent(),
                Value<String> manifestId = const Value.absent(),
                Value<String> type = const Value.absent(),
                Value<String> fileHash = const Value.absent(),
                Value<int> offsetMs = const Value.absent(),
                Value<int> hlcPt = const Value.absent(),
                Value<int> hlcC = const Value.absent(),
                Value<int> wallMs = const Value.absent(),
                Value<int> tzMin = const Value.absent(),
                Value<String> source = const Value.absent(),
                Value<String> dataJson = const Value.absent(),
                Value<bool> synced = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => EventRowsCompanion(
                eventId: eventId,
                deviceId: deviceId,
                sessionId: sessionId,
                bookId: bookId,
                manifestId: manifestId,
                type: type,
                fileHash: fileHash,
                offsetMs: offsetMs,
                hlcPt: hlcPt,
                hlcC: hlcC,
                wallMs: wallMs,
                tzMin: tzMin,
                source: source,
                dataJson: dataJson,
                synced: synced,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String eventId,
                required String deviceId,
                required String sessionId,
                required String bookId,
                required String manifestId,
                required String type,
                required String fileHash,
                required int offsetMs,
                required int hlcPt,
                required int hlcC,
                required int wallMs,
                required int tzMin,
                required String source,
                Value<String> dataJson = const Value.absent(),
                Value<bool> synced = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => EventRowsCompanion.insert(
                eventId: eventId,
                deviceId: deviceId,
                sessionId: sessionId,
                bookId: bookId,
                manifestId: manifestId,
                type: type,
                fileHash: fileHash,
                offsetMs: offsetMs,
                hlcPt: hlcPt,
                hlcC: hlcC,
                wallMs: wallMs,
                tzMin: tzMin,
                source: source,
                dataJson: dataJson,
                synced: synced,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$EventRowsTable, EventRow>(table),
                  BaseReferences<_$AppDatabase, $EventRowsTable, EventRow>(
                    db,
                    table,
                    e,
                  ),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$EventRowsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $EventRowsTable,
      EventRow,
      $$EventRowsTableFilterComposer,
      $$EventRowsTableOrderingComposer,
      $$EventRowsTableAnnotationComposer,
      $$EventRowsTableCreateCompanionBuilder,
      $$EventRowsTableUpdateCompanionBuilder,
      (EventRow, BaseReferences<_$AppDatabase, $EventRowsTable, EventRow>),
      EventRow,
      PrefetchHooks Function()
    >;
typedef $$SyncStateTableCreateCompanionBuilder = SyncStateCompanion Function({
  Value<int> id,
  Value<int> sinceSeq,
});
typedef $$SyncStateTableUpdateCompanionBuilder = SyncStateCompanion Function({
  Value<int> id,
  Value<int> sinceSeq,
});

class $$SyncStateTableFilterComposer
    extends Composer<_$AppDatabase, $SyncStateTable> {
  $$SyncStateTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get sinceSeq => $composableBuilder(
    column: $table.sinceSeq,
    builder: (column) => ColumnFilters(column),
  );
}

class $$SyncStateTableOrderingComposer
    extends Composer<_$AppDatabase, $SyncStateTable> {
  $$SyncStateTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get sinceSeq => $composableBuilder(
    column: $table.sinceSeq,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$SyncStateTableAnnotationComposer
    extends Composer<_$AppDatabase, $SyncStateTable> {
  $$SyncStateTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<int> get sinceSeq =>
      $composableBuilder(column: $table.sinceSeq, builder: (column) => column);
}

class $$SyncStateTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $SyncStateTable,
          SyncStateData,
          $$SyncStateTableFilterComposer,
          $$SyncStateTableOrderingComposer,
          $$SyncStateTableAnnotationComposer,
          $$SyncStateTableCreateCompanionBuilder,
          $$SyncStateTableUpdateCompanionBuilder,
          (
            SyncStateData,
            BaseReferences<_$AppDatabase, $SyncStateTable, SyncStateData>,
          ),
          SyncStateData,
          PrefetchHooks Function()
        > {
  $$SyncStateTableTableManager(_$AppDatabase db, $SyncStateTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$SyncStateTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$SyncStateTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$SyncStateTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<int> id = const Value.absent(),
            Value<int> sinceSeq = const Value.absent(),
          }) => SyncStateCompanion(id: id, sinceSeq: sinceSeq),
          createCompanionCallback: ({
            Value<int> id = const Value.absent(),
            Value<int> sinceSeq = const Value.absent(),
          }) => SyncStateCompanion.insert(id: id, sinceSeq: sinceSeq),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$SyncStateTable, SyncStateData>(table),
                  BaseReferences<_$AppDatabase, $SyncStateTable, SyncStateData>(
                    db,
                    table,
                    e,
                  ),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$SyncStateTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $SyncStateTable,
      SyncStateData,
      $$SyncStateTableFilterComposer,
      $$SyncStateTableOrderingComposer,
      $$SyncStateTableAnnotationComposer,
      $$SyncStateTableCreateCompanionBuilder,
      $$SyncStateTableUpdateCompanionBuilder,
      (
        SyncStateData,
        BaseReferences<_$AppDatabase, $SyncStateTable, SyncStateData>,
      ),
      SyncStateData,
      PrefetchHooks Function()
    >;
typedef $$KeyValueSettingsTableCreateCompanionBuilder =
    KeyValueSettingsCompanion Function({
      required String key,
      required String value,
      Value<int> rowid,
    });
typedef $$KeyValueSettingsTableUpdateCompanionBuilder =
    KeyValueSettingsCompanion Function({
      Value<String> key,
      Value<String> value,
      Value<int> rowid,
    });

class $$KeyValueSettingsTableFilterComposer
    extends Composer<_$AppDatabase, $KeyValueSettingsTable> {
  $$KeyValueSettingsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get key => $composableBuilder(
    column: $table.key,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get value => $composableBuilder(
    column: $table.value,
    builder: (column) => ColumnFilters(column),
  );
}

class $$KeyValueSettingsTableOrderingComposer
    extends Composer<_$AppDatabase, $KeyValueSettingsTable> {
  $$KeyValueSettingsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get key => $composableBuilder(
    column: $table.key,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get value => $composableBuilder(
    column: $table.value,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$KeyValueSettingsTableAnnotationComposer
    extends Composer<_$AppDatabase, $KeyValueSettingsTable> {
  $$KeyValueSettingsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get key =>
      $composableBuilder(column: $table.key, builder: (column) => column);

  GeneratedColumn<String> get value =>
      $composableBuilder(column: $table.value, builder: (column) => column);
}

class $$KeyValueSettingsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $KeyValueSettingsTable,
          KeyValueSetting,
          $$KeyValueSettingsTableFilterComposer,
          $$KeyValueSettingsTableOrderingComposer,
          $$KeyValueSettingsTableAnnotationComposer,
          $$KeyValueSettingsTableCreateCompanionBuilder,
          $$KeyValueSettingsTableUpdateCompanionBuilder,
          (
            KeyValueSetting,
            BaseReferences<
              _$AppDatabase,
              $KeyValueSettingsTable,
              KeyValueSetting
            >,
          ),
          KeyValueSetting,
          PrefetchHooks Function()
        > {
  $$KeyValueSettingsTableTableManager(
    _$AppDatabase db,
    $KeyValueSettingsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$KeyValueSettingsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$KeyValueSettingsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$KeyValueSettingsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<String> key = const Value.absent(),
            Value<String> value = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) => KeyValueSettingsCompanion(key: key, value: value, rowid: rowid),
          createCompanionCallback:
              ({
                required String key,
                required String value,
                Value<int> rowid = const Value.absent(),
              }) => KeyValueSettingsCompanion.insert(
                key: key,
                value: value,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$KeyValueSettingsTable, KeyValueSetting>(table),
                  BaseReferences<
                    _$AppDatabase,
                    $KeyValueSettingsTable,
                    KeyValueSetting
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$KeyValueSettingsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $KeyValueSettingsTable,
      KeyValueSetting,
      $$KeyValueSettingsTableFilterComposer,
      $$KeyValueSettingsTableOrderingComposer,
      $$KeyValueSettingsTableAnnotationComposer,
      $$KeyValueSettingsTableCreateCompanionBuilder,
      $$KeyValueSettingsTableUpdateCompanionBuilder,
      (
        KeyValueSetting,
        BaseReferences<_$AppDatabase, $KeyValueSettingsTable, KeyValueSetting>,
      ),
      KeyValueSetting,
      PrefetchHooks Function()
    >;

class $AppDatabaseManager {
  final _$AppDatabase _db;
  $AppDatabaseManager(this._db);
  $$EventRowsTableTableManager get eventRows =>
      $$EventRowsTableTableManager(_db, _db.eventRows);
  $$SyncStateTableTableManager get syncState =>
      $$SyncStateTableTableManager(_db, _db.syncState);
  $$KeyValueSettingsTableTableManager get keyValueSettings =>
      $$KeyValueSettingsTableTableManager(_db, _db.keyValueSettings);
}
