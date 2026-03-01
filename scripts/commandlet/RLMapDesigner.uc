/**
 * RLMapDesigner Commandlet
 * Reads arena_build.json and creates a UDK map with:
 *   - Arena geometry (scaled StaticMeshActors for floor/walls/ceiling)
 *   - VehiclePickup_Boost_TA actors (boost pads)
 *   - GoalVolume_TA actors (goals, freely sized/positioned/rotated)
 *   - PlayerStart_TA actors (spawn points)
 *   - Pylon_Soccar_TA actor (ball spawn)
 * Outputs: UDKGame/Content/Maps/RLMapDesigner_Output.udk
 *
 * Compile once: UDK.exe make -full
 * Run:          UDK.exe RLMapDesigner -run=RLMapDesignerCommandlet -noprompt
 */
class RLMapDesignerCommandlet extends Commandlet
    config(RLMapDesigner);

// Path to the arena JSON file — set by server.py via UDKRLMapDesigner.ini
var config string JsonPath;

// ─────────────────────────────────────────────────────────────────────────────
//  Entry point
// ─────────────────────────────────────────────────────────────────────────────
function int Main(string Params)
{
    local string JsonText;
    local JsonObject RootConfig, Arena, ObjectsArray, ObjEntry;
    local int i, NumObjects;
    local string ObjType;

    `log("RLMapDesigner: Starting commandlet");
    `log("RLMapDesigner: JsonPath=" $ JsonPath);

    // Read JSON
    JsonText = "";
    if (!class'FileHelper'.static.ReadStringFromFile(JsonPath, JsonText))
    {
        `error("RLMapDesigner: Failed to read JSON from: " $ JsonPath);
        return 1;
    }

    RootConfig = class'JsonObject'.static.DecodeJson(JsonText);
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
function BuildArenaGeometry(JsonObject Arena)
{
    local float FW, FL, WH, CR;
    local bool  HasWalls, HasCeiling;
    local StaticMeshActor Panel;
    local StaticMesh FloorMesh, WallMesh;

    // Dimensions in Unreal Units (already multiplied by 85.3 by server.py)
    FW = Arena.GetFloatValue("fw_uu");
    FL = Arena.GetFloatValue("fl_uu");
    WH = Arena.GetFloatValue("wh_uu");
    CR = Arena.GetFloatValue("cornerR_uu");
    HasWalls    = Arena.GetIntValue("walls") != 0;
    HasCeiling  = Arena.GetIntValue("ceiling") != 0;

    `log("RLMapDesigner: Arena " $ FW $ "x" $ FL $ "x" $ WH $ " UU");

    // Floor
    Panel = Spawn(class'StaticMeshActor', None, 'Floor',
        vect(0, 0, 0), rot(0, 0, 0));
    if (Panel != None)
    {
        Panel.StaticMeshComponent.SetStaticMesh(
            StaticMesh(DynamicLoadObject("Stadium_OOB.Floor_Plane", class'StaticMesh')));
        Panel.SetDrawScale3D(vect(1,1,1) * 0.0);  // will be set properly below
        // Use actual floor panel from RL dummy assets, scaled to arena dimensions
        Panel.StaticMeshComponent.SetTranslation(vect(0, 0, 0));
        // DrawScale3D: X=FW/100, Y=FL/100 (base mesh is 100x100 UU)
        Panel.DrawScale3D.X = FW / 100.0;
        Panel.DrawScale3D.Y = FL / 100.0;
        Panel.DrawScale3D.Z = 1.0;
    }

    if (HasWalls)
    {
        // +X wall
        SpawnWallPanel(FW/2, 0, WH/2, 0, FL, WH, 0, 16384);
        // -X wall
        SpawnWallPanel(-FW/2, 0, WH/2, 0, FL, WH, 0, -16384);
        // +Z wall (end wall)
        SpawnWallPanel(0, FL/2, WH/2, FL, 0, WH, 16384, 0);
        // -Z wall (end wall)
        SpawnWallPanel(0, -FL/2, WH/2, FL, 0, WH, -16384, 0);
    }

    if (HasCeiling)
    {
        Panel = Spawn(class'StaticMeshActor', None, 'Ceiling',
            MakeVector(0, 0, WH), rot(32768, 0, 0));
        if (Panel != None)
        {
            Panel.DrawScale3D.X = FW / 100.0;
            Panel.DrawScale3D.Y = FL / 100.0;
            Panel.DrawScale3D.Z = 1.0;
        }
    }
}

function SpawnWallPanel(
    float PX, float PY, float PZ,
    float ScaleX, float ScaleY, float ScaleZ,
    int Pitch, int Yaw)
{
    local StaticMeshActor Panel;
    Panel = Spawn(class'StaticMeshActor', None, '',
        MakeVector(PX, PY, PZ), MakeRotator(Pitch, Yaw, 0));
    if (Panel != None)
    {
        Panel.DrawScale3D.X = max(ScaleX, 1.0) / 100.0;
        Panel.DrawScale3D.Y = max(ScaleY, 1.0) / 100.0;
        Panel.DrawScale3D.Z = max(ScaleZ, 1.0) / 100.0;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
//  Object placement helpers
// ─────────────────────────────────────────────────────────────────────────────
function Vector GetPosition(JsonObject Obj)
{
    local JsonObject PosUU;
    local Vector V;
    // position_uu array: [x_uu, y_uu, z_uu]  (already in Unreal Units)
    PosUU = Obj.GetObject("position_uu");
    if (PosUU != None && PosUU.ValueArray.Length >= 3)
    {
        V.X = float(PosUU.ValueArray[0].StringValue);
        V.Y = -float(PosUU.ValueArray[2].StringValue);  // Three.js +Z → UE -Y (RH→LH flip)
        V.Z = float(PosUU.ValueArray[1].StringValue);  // Three.js Y → UE Z
    }
    return V;
}

function Rotator GetRotation(JsonObject Obj)
{
    local JsonObject RotArr;
    local Rotator R;
    local float RX, RY, RZ;
    RotArr = Obj.GetObject("rotation");
    if (RotArr != None && RotArr.ValueArray.Length >= 3)
    {
        RX = float(RotArr.ValueArray[0].StringValue);  // pitch (rad)
        RY = float(RotArr.ValueArray[1].StringValue);  // yaw
        RZ = float(RotArr.ValueArray[2].StringValue);  // roll
        // rad → Unreal rotation units (1 rad = 10430.38 URU)
        R.Pitch = int(RZ * 10430.38);  // Three.js Z-rot → UE Pitch
        R.Yaw   = int(RY * 10430.38);  // Three.js Y-rot → UE Yaw
        R.Roll  = int(RX * 10430.38);  // Three.js X-rot → UE Roll
    }
    return R;
}

function PlaceBoostPad(JsonObject Obj)
{
    local Vector Pos;
    local Rotator Rot;
    local VehiclePickup_Boost_TA Pad;
    local JsonObject Props;
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
        {
            Pad.RespawnTime = Props.GetFloatValue("respawnTime");
        }
        if (!IsLarge)
        {
            Pad.DrawScale = 0.7;
        }
    }
    else
    {
        `warn("RLMapDesigner: Failed to spawn boost pad at " $ Pos);
    }
}

function PlaceGoal(JsonObject Obj)
{
    local Vector Pos;
    local Rotator Rot;
    local GoalVolume_TA Goal;
    local JsonObject Props;
    local float GW, GH, GD;
    local int Team;

    Pos = GetPosition(Obj);
    Rot = GetRotation(Obj);
    Props = Obj.GetObject("properties");

    Goal = Spawn(class'GoalVolume_TA', None, '', Pos, Rot);
    if (Goal != None && Props != None)
    {
        Team = int(Props.GetStringValue("team"));
        GW = Props.GetFloatValue("width_uu");
        GH = Props.GetFloatValue("height_uu");
        GD = Props.GetFloatValue("depth_uu");

        Goal.Team = Team;
        // Scale the brush component to match desired dimensions
        // Base brush is 1x1x1 UU; DrawScale3D sets actual size
        Goal.DrawScale3D.X = max(GW, 1.0);
        Goal.DrawScale3D.Y = max(GD, 1.0);
        Goal.DrawScale3D.Z = max(GH, 1.0);
    }
    else
    {
        `warn("RLMapDesigner: Failed to spawn goal at " $ Pos);
    }
}

function PlacePlayerStart(JsonObject Obj)
{
    local Vector Pos;
    local Rotator Rot;
    local PlayerStart_TA Start;
    local JsonObject Props;

    Pos = GetPosition(Obj);
    Rot = GetRotation(Obj);
    Props = Obj.GetObject("properties");

    Start = Spawn(class'PlayerStart_TA', None, '', Pos, Rot);
    if (Start != None && Props != None)
    {
        Start.TeamNum = int(Props.GetStringValue("team"));
    }
}

function PlaceBallSpawn(JsonObject Obj)
{
    local Vector Pos;
    local Rotator Rot;
    local Pylon_Soccar_TA BallSpawn;

    Pos = GetPosition(Obj);
    Rot = GetRotation(Obj);

    BallSpawn = Spawn(class'Pylon_Soccar_TA', None, '', Pos, Rot);
    if (BallSpawn == None)
    {
        `warn("RLMapDesigner: Failed to spawn ball spawn at " $ Pos);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
//  Save map
// ─────────────────────────────────────────────────────────────────────────────
function SaveMap()
{
    local string OutPath;
    OutPath = "UDKGame/Content/Maps/RLMapDesigner_Output";
    `log("RLMapDesigner: Saving map to " $ OutPath);

    if (!SavePackage(GetCurrentWorld().GetOutermost(), OutPath, 0, "", None))
    {
        `error("RLMapDesigner: SavePackage failed for " $ OutPath);
    }
    else
    {
        `log("RLMapDesigner: Map saved successfully.");
    }
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
    IsEditor=False
    IsServer=True
    LogToConsole=True
    ShowErrorCount=True
}
