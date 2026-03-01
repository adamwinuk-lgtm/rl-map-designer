/**
 * RLMapDesigner Commandlet
 * Reads arena JSON from config (set via UDKRLMapDesigner.ini by server.py)
 * and creates a UDK map with arena geometry + all placed objects.
 *
 * Compile once: UDK.exe make -full
 * Run:          UDK.exe RLMapDesigner -run=RLMapDesignerCommandlet -noprompt
 */
class RLMapDesignerCommandlet extends Commandlet
    config(RLMapDesigner)
    dependson(IpDrv.JsonObject);

// Path to arena JSON file — set by server.py via UDKRLMapDesigner.ini
var config string JsonPath;

// ─────────────────────────────────────────────────────────────────────────────
//  Entry point
// ─────────────────────────────────────────────────────────────────────────────
function int Main(string Params)
{
    local string JsonText;
    local IpDrv.JsonObject RootConfig, Arena, ObjectsArray, ObjEntry;
    local int i, NumObjects;
    local string ObjType;

    `log("RLMapDesigner: Starting commandlet");
    `log("RLMapDesigner: JsonPath=" $ JsonPath);

    // Read JSON via FileHelper (Editor package)
    JsonText = "";
    if (!class'Editor.FileHelper'.static.ReadStringFromFile(JsonPath, JsonText))
    {
        `error("RLMapDesigner: Failed to read JSON from: " $ JsonPath);
        return 1;
    }

    RootConfig = class'IpDrv.JsonObject'.static.DecodeJson(JsonText);
    if (RootConfig == None)
    {
        `error("RLMapDesigner: Failed to parse JSON");
        return 1;
    }

    // Build arena geometry
    Arena = RootConfig.GetObject("arena");
    if (Arena != None)
    {
        BuildArenaGeometry(Arena);
    }

    // Place all objects
    ObjectsArray = RootConfig.GetObject("objects");
    if (ObjectsArray != None)
    {
        NumObjects = ObjectsArray.ValueArray.Length;
        `log("RLMapDesigner: Placing " $ NumObjects $ " objects");

        for (i = 0; i < NumObjects; i++)
        {
            ObjEntry = ObjectsArray.ValueArray[i];
            ObjType = ObjEntry.GetStringValue("type");

            if (ObjType == "boost_large" || ObjType == "boost_small")
                PlaceBoostPad(ObjEntry);
            else if (ObjType == "goal")
                PlaceGoal(ObjEntry);
            else if (ObjType == "spawn_blue" || ObjType == "spawn_orange")
                PlacePlayerStart(ObjEntry);
            else if (ObjType == "ball_spawn")
                PlaceBallSpawn(ObjEntry);
            else
                `warn("RLMapDesigner: Unknown object type: " $ ObjType);
        }
    }

    // Save the map
    SaveMap();
    `log("RLMapDesigner: Done.");
    return 0;
}

// ─────────────────────────────────────────────────────────────────────────────
//  Arena geometry
// ─────────────────────────────────────────────────────────────────────────────
function BuildArenaGeometry(IpDrv.JsonObject Arena)
{
    local float FW, FL, WH;
    local bool  HasWalls, HasCeiling;
    local StaticMeshActor Panel;
    local StaticMesh FloorMesh;

    // Dimensions in Unreal Units (pre-multiplied by 85.333 by server.py)
    FW = Arena.GetFloatValue("fw_uu");
    FL = Arena.GetFloatValue("fl_uu");
    WH = Arena.GetFloatValue("wh_uu");
    HasWalls   = Arena.GetIntValue("walls") != 0;
    HasCeiling = Arena.GetIntValue("ceiling") != 0;

    `log("RLMapDesigner: Arena " $ FW $ "x" $ FL $ "x" $ WH $ " UU");

    FloorMesh = StaticMesh(DynamicLoadObject("Stadium_OOB.Floor_Plane", class'StaticMesh'));

    // Floor — use '' for Name to avoid conflicts on re-run
    Panel = Spawn(class'StaticMeshActor', None, '', vect(0,0,0), rot(0,0,0));
    if (Panel != None)
    {
        Panel.StaticMeshComponent.SetStaticMesh(FloorMesh);
        Panel.SetDrawScale3D(MakeVector(FW / 100.0, FL / 100.0, 1.0));
    }

    if (HasWalls)
    {
        // +X side wall
        SpawnWallPanel( FW/2, 0, WH/2, FL, WH, 0, 16384);
        // -X side wall
        SpawnWallPanel(-FW/2, 0, WH/2, FL, WH, 0, -16384);
        // +Y end wall (FW wide — end wall spans the arena width)
        SpawnWallPanel(0,  FL/2, WH/2, FW, WH, 16384, 0);
        // -Y end wall
        SpawnWallPanel(0, -FL/2, WH/2, FW, WH, -16384, 0);
    }

    if (HasCeiling)
    {
        Panel = Spawn(class'StaticMeshActor', None, '', MakeVector(0, 0, WH), MakeRotator(32768, 0, 0));
        if (Panel != None)
        {
            Panel.StaticMeshComponent.SetStaticMesh(FloorMesh);
            Panel.SetDrawScale3D(MakeVector(FW / 100.0, FL / 100.0, 1.0));
        }
    }
}

function SpawnWallPanel(
    float PX, float PY, float PZ,
    float ScaleX, float ScaleZ,
    int Pitch, int Yaw)
{
    local StaticMeshActor Panel;
    local StaticMesh WallMesh;
    WallMesh = StaticMesh(DynamicLoadObject("Stadium_OOB.Floor_Plane", class'StaticMesh'));
    Panel = Spawn(class'StaticMeshActor', None, '',
        MakeVector(PX, PY, PZ), MakeRotator(Pitch, Yaw, 0));
    if (Panel != None)
    {
        Panel.StaticMeshComponent.SetStaticMesh(WallMesh);
        Panel.SetDrawScale3D(MakeVector(max(ScaleX, 1.0) / 100.0, 0.01, max(ScaleZ, 1.0) / 100.0));
    }
}

// ─────────────────────────────────────────────────────────────────────────────
//  Object placement helpers
// ─────────────────────────────────────────────────────────────────────────────
function Vector GetPosition(IpDrv.JsonObject Obj)
{
    local IpDrv.JsonObject PosUU;
    local Vector V;
    // position_uu: [x_uu, y_uu, z_uu] in Three.js space
    // Three.js X → UE X, Three.js Y → UE Z, Three.js Z → UE -Y (LH flip)
    PosUU = Obj.GetObject("position_uu");
    if (PosUU != None && PosUU.ValueArray.Length >= 3)
    {
        V.X =  PosUU.ValueArray[0].FloatValue;
        V.Y = -PosUU.ValueArray[2].FloatValue;  // Three.js +Z → UE -Y
        V.Z =  PosUU.ValueArray[1].FloatValue;  // Three.js Y → UE Z
    }
    return V;
}

function Rotator GetRotation(IpDrv.JsonObject Obj)
{
    local IpDrv.JsonObject RotArr;
    local Rotator R;
    local float RX, RY, RZ;
    RotArr = Obj.GetObject("rotation");
    if (RotArr != None && RotArr.ValueArray.Length >= 3)
    {
        RX = RotArr.ValueArray[0].FloatValue;  // Three.js X (rad)
        RY = RotArr.ValueArray[1].FloatValue;  // Three.js Y (rad)
        RZ = RotArr.ValueArray[2].FloatValue;  // Three.js Z (rad)
        // Three.js Z-rot → UE Pitch, Y-rot → UE Yaw, X-rot → UE Roll
        // 1 rad = 10430.38 Unreal Rotation Units
        R.Pitch = int(RZ * 10430.38);
        R.Yaw   = int(RY * 10430.38);
        R.Roll  = int(RX * 10430.38);
    }
    return R;
}

function PlaceBoostPad(IpDrv.JsonObject Obj)
{
    local Vector Pos;
    local Rotator Rot;
    local VehiclePickup_Boost_TA Pad;
    local IpDrv.JsonObject Props;
    local bool IsLarge;

    Pos = GetPosition(Obj);
    Rot = GetRotation(Obj);
    Props = Obj.GetObject("properties");
    IsLarge = (Props != None && Props.GetStringValue("size") == "large");

    Pad = Spawn(class'VehiclePickup_Boost_TA', None, '', Pos, Rot);
    if (Pad != None)
    {
        Pad.bIsBig = IsLarge;
        if (Props != None)
            Pad.RespawnTime = Props.GetFloatValue("respawnTime");
        if (!IsLarge)
            Pad.DrawScale = 0.7;
    }
    else
    {
        `warn("RLMapDesigner: Failed to spawn boost pad at " $ Pos);
    }
}

function PlaceGoal(IpDrv.JsonObject Obj)
{
    local Vector Pos;
    local Rotator Rot;
    local GoalVolume_TA Goal;
    local IpDrv.JsonObject Props;
    local float GW, GH, GD;

    Pos = GetPosition(Obj);
    Rot = GetRotation(Obj);
    Props = Obj.GetObject("properties");

    Goal = Spawn(class'GoalVolume_TA', None, '', Pos, Rot);
    if (Goal != None && Props != None)
    {
        Goal.Team = int(Props.GetStringValue("team"));
        GW = Props.GetFloatValue("width_uu");
        GH = Props.GetFloatValue("height_uu");
        GD = Props.GetFloatValue("depth_uu");
        Goal.SetDrawScale3D(MakeVector(max(GW, 1.0), max(GD, 1.0), max(GH, 1.0)));
    }
    else
    {
        `warn("RLMapDesigner: Failed to spawn goal at " $ Pos);
    }
}

function PlacePlayerStart(IpDrv.JsonObject Obj)
{
    local Vector Pos;
    local Rotator Rot;
    local PlayerStart_TA Start;
    local IpDrv.JsonObject Props;

    Pos = GetPosition(Obj);
    Rot = GetRotation(Obj);
    Props = Obj.GetObject("properties");

    Start = Spawn(class'PlayerStart_TA', None, '', Pos, Rot);
    if (Start != None && Props != None)
        Start.TeamNum = int(Props.GetStringValue("team"));
}

function PlaceBallSpawn(IpDrv.JsonObject Obj)
{
    local Vector Pos;
    local Rotator Rot;
    local Pylon_Soccar_TA BallSpawn;

    Pos = GetPosition(Obj);
    Rot = GetRotation(Obj);

    BallSpawn = Spawn(class'Pylon_Soccar_TA', None, '', Pos, Rot);
    if (BallSpawn == None)
        `warn("RLMapDesigner: Failed to spawn ball spawn at " $ Pos);
}

// ─────────────────────────────────────────────────────────────────────────────
//  Save map
// ─────────────────────────────────────────────────────────────────────────────
function SaveMap()
{
    local string OutPath;
    local WorldInfo WI;
    OutPath = "UDKGame/Content/Maps/RLMapDesigner_Output";
    `log("RLMapDesigner: Saving map to " $ OutPath);

    WI = class'WorldInfo'.static.GetWorldInfo();
    if (WI == None)
    {
        `error("RLMapDesigner: Could not get WorldInfo for SavePackage");
        return;
    }
    if (!SavePackage(WI.GetOutermost(), OutPath, 0, "", None))
        `error("RLMapDesigner: SavePackage failed for " $ OutPath);
    else
        `log("RLMapDesigner: Map saved successfully.");
}

// ─────────────────────────────────────────────────────────────────────────────
//  Utility
// ─────────────────────────────────────────────────────────────────────────────
static function Vector MakeVector(float X, float Y, float Z)
{
    local Vector V;
    V.X = X; V.Y = Y; V.Z = Z;
    return V;
}

static function Rotator MakeRotator(int Pitch, int Yaw, int Roll)
{
    local Rotator R;
    R.Pitch = Pitch; R.Yaw = Yaw; R.Roll = Roll;
    return R;
}

defaultproperties
{
    IsClient=False
    IsEditor=True
    IsServer=True
    LogToConsole=True
    ShowErrorCount=True
}
