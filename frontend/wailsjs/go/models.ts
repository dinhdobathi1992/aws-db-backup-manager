export namespace model {
	
	export class AWSBackupPlanRef {
	    planId: string;
	    planName: string;
	    ruleName: string;
	    cron: string;
	    lifecycle: string;
	    vault: string;
	
	    static createFrom(source: any = {}) {
	        return new AWSBackupPlanRef(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.planId = source["planId"];
	        this.planName = source["planName"];
	        this.ruleName = source["ruleName"];
	        this.cron = source["cron"];
	        this.lifecycle = source["lifecycle"];
	        this.vault = source["vault"];
	    }
	}
	export class Account {
	    id: string;
	    name: string;
	    profile: string;
	    regions: string[];
	    color: string;
	    readOnly: boolean;
	
	    static createFrom(source: any = {}) {
	        return new Account(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.id = source["id"];
	        this.name = source["name"];
	        this.profile = source["profile"];
	        this.regions = source["regions"];
	        this.color = source["color"];
	        this.readOnly = source["readOnly"];
	    }
	}
	export class AccountStatus {
	    accountId: string;
	    arn: string;
	    awsAccountId: string;
	    state: string;
	    message: string;
	
	    static createFrom(source: any = {}) {
	        return new AccountStatus(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.accountId = source["accountId"];
	        this.arn = source["arn"];
	        this.awsAccountId = source["awsAccountId"];
	        this.state = source["state"];
	        this.message = source["message"];
	    }
	}
	export class Activity {
	    time: string;
	    source: string;
	    db: string;
	    action: string;
	    status: string;
	    message: string;
	
	    static createFrom(source: any = {}) {
	        return new Activity(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.time = source["time"];
	        this.source = source["source"];
	        this.db = source["db"];
	        this.action = source["action"];
	        this.status = source["status"];
	        this.message = source["message"];
	    }
	}
	export class AutomatedBackupSummary {
	    retention: number;
	    window: string;
	    earliest?: string;
	    latest?: string;
	
	    static createFrom(source: any = {}) {
	        return new AutomatedBackupSummary(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.retention = source["retention"];
	        this.window = source["window"];
	        this.earliest = source["earliest"];
	        this.latest = source["latest"];
	    }
	}
	export class ManualBackupSummary {
	    count: number;
	    latest?: string;
	
	    static createFrom(source: any = {}) {
	        return new ManualBackupSummary(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.count = source["count"];
	        this.latest = source["latest"];
	    }
	}
	export class BackupPlanSummary {
	    db: string;
	    manual: ManualBackupSummary;
	    automated: AutomatedBackupSummary;
	    awsBackup: AWSBackupPlanRef[];
	
	    static createFrom(source: any = {}) {
	        return new BackupPlanSummary(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.db = source["db"];
	        this.manual = this.convertValues(source["manual"], ManualBackupSummary);
	        this.automated = this.convertValues(source["automated"], AutomatedBackupSummary);
	        this.awsBackup = this.convertValues(source["awsBackup"], AWSBackupPlanRef);
	    }
	
		convertValues(a: any, classs: any, asMap: boolean = false): any {
		    if (!a) {
		        return a;
		    }
		    if (a.slice && a.map) {
		        return (a as any[]).map(elem => this.convertValues(elem, classs));
		    } else if ("object" === typeof a) {
		        if (asMap) {
		            for (const key of Object.keys(a)) {
		                a[key] = new classs(a[key]);
		            }
		            return a;
		        }
		        return new classs(a);
		    }
		    return a;
		}
	}
	export class CreateBackupPlanReq {
	    accountId: string;
	    region: string;
	    kind: string;
	    dbIdentifier: string;
	    planName: string;
	    ruleName: string;
	    cron: string;
	    vaultName: string;
	    retentionDays: number;
	    iamRoleArn: string;
	
	    static createFrom(source: any = {}) {
	        return new CreateBackupPlanReq(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.accountId = source["accountId"];
	        this.region = source["region"];
	        this.kind = source["kind"];
	        this.dbIdentifier = source["dbIdentifier"];
	        this.planName = source["planName"];
	        this.ruleName = source["ruleName"];
	        this.cron = source["cron"];
	        this.vaultName = source["vaultName"];
	        this.retentionDays = source["retentionDays"];
	        this.iamRoleArn = source["iamRoleArn"];
	    }
	}
	export class CreateSnapshotReq {
	    accountId: string;
	    region: string;
	    kind: string;
	    dbIdentifier: string;
	    snapshotName: string;
	
	    static createFrom(source: any = {}) {
	        return new CreateSnapshotReq(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.accountId = source["accountId"];
	        this.region = source["region"];
	        this.kind = source["kind"];
	        this.dbIdentifier = source["dbIdentifier"];
	        this.snapshotName = source["snapshotName"];
	    }
	}
	export class Database {
	    accountId: string;
	    region: string;
	    kind: string;
	    identifier: string;
	    engine: string;
	    engineVersion: string;
	    class: string;
	    status: string;
	    endpoint: string;
	    multiAz: boolean;
	    storageGb: number;
	    encrypted: boolean;
	    backupRetentionDays: number;
	    preferredBackupWindow: string;
	    latestRestorableTime?: string;
	    tags?: Record<string, string>;
	
	    static createFrom(source: any = {}) {
	        return new Database(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.accountId = source["accountId"];
	        this.region = source["region"];
	        this.kind = source["kind"];
	        this.identifier = source["identifier"];
	        this.engine = source["engine"];
	        this.engineVersion = source["engineVersion"];
	        this.class = source["class"];
	        this.status = source["status"];
	        this.endpoint = source["endpoint"];
	        this.multiAz = source["multiAz"];
	        this.storageGb = source["storageGb"];
	        this.encrypted = source["encrypted"];
	        this.backupRetentionDays = source["backupRetentionDays"];
	        this.preferredBackupWindow = source["preferredBackupWindow"];
	        this.latestRestorableTime = source["latestRestorableTime"];
	        this.tags = source["tags"];
	    }
	}
	
	export class ModifyAutomatedBackupReq {
	    accountId: string;
	    region: string;
	    kind: string;
	    dbIdentifier: string;
	    window?: string;
	    retentionDays?: number;
	
	    static createFrom(source: any = {}) {
	        return new ModifyAutomatedBackupReq(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.accountId = source["accountId"];
	        this.region = source["region"];
	        this.kind = source["kind"];
	        this.dbIdentifier = source["dbIdentifier"];
	        this.window = source["window"];
	        this.retentionDays = source["retentionDays"];
	    }
	}
	export class RestoreReq {
	    accountId: string;
	    region: string;
	    kind: string;
	    source: string;
	    sourceDbIdentifier: string;
	    snapshotId?: string;
	    recoveryPointArn?: string;
	    restoreTime?: string;
	    targetIdentifier: string;
	    instanceClass?: string;
	    subnetGroup?: string;
	    securityGroups?: string[];
	    publiclyAccessible: boolean;
	
	    static createFrom(source: any = {}) {
	        return new RestoreReq(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.accountId = source["accountId"];
	        this.region = source["region"];
	        this.kind = source["kind"];
	        this.source = source["source"];
	        this.sourceDbIdentifier = source["sourceDbIdentifier"];
	        this.snapshotId = source["snapshotId"];
	        this.recoveryPointArn = source["recoveryPointArn"];
	        this.restoreTime = source["restoreTime"];
	        this.targetIdentifier = source["targetIdentifier"];
	        this.instanceClass = source["instanceClass"];
	        this.subnetGroup = source["subnetGroup"];
	        this.securityGroups = source["securityGroups"];
	        this.publiclyAccessible = source["publiclyAccessible"];
	    }
	}
	export class Schedule {
	    source: string;
	    db: string;
	    expression: string;
	    nextRun?: string;
	    retention: number;
	
	    static createFrom(source: any = {}) {
	        return new Schedule(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.source = source["source"];
	        this.db = source["db"];
	        this.expression = source["expression"];
	        this.nextRun = source["nextRun"];
	        this.retention = source["retention"];
	    }
	}
	export class Snapshot {
	    id: string;
	    arn: string;
	    dbIdentifier: string;
	    kind: string;
	    source: string;
	    status: string;
	    createdAt: string;
	    sizeGb: number;
	    encrypted: boolean;
	    engine: string;
	    vaultName?: string;
	
	    static createFrom(source: any = {}) {
	        return new Snapshot(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.id = source["id"];
	        this.arn = source["arn"];
	        this.dbIdentifier = source["dbIdentifier"];
	        this.kind = source["kind"];
	        this.source = source["source"];
	        this.status = source["status"];
	        this.createdAt = source["createdAt"];
	        this.sizeGb = source["sizeGb"];
	        this.encrypted = source["encrypted"];
	        this.engine = source["engine"];
	        this.vaultName = source["vaultName"];
	    }
	}
	export class StartBackupJobReq {
	    accountId: string;
	    region: string;
	    kind: string;
	    dbIdentifier: string;
	    vaultName: string;
	    iamRoleArn: string;
	
	    static createFrom(source: any = {}) {
	        return new StartBackupJobReq(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.accountId = source["accountId"];
	        this.region = source["region"];
	        this.kind = source["kind"];
	        this.dbIdentifier = source["dbIdentifier"];
	        this.vaultName = source["vaultName"];
	        this.iamRoleArn = source["iamRoleArn"];
	    }
	}

}

