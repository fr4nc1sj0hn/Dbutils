/**
	Summary:
		Process the flattened CQ Table into Parent Child Relationship and transforming into dimGroup

	Example:
		EXEC dbo.uspAddCQToDimGroup
			@ParametersFromTable = 1
	Returns: None

	Change History
	==============================================================
	3/16/2018	FRANC583	Initial Version
	1/17/2019	FRANC583	CPA-608
	3/28/2019	FRANC583	CPA-674
	03/26/2020	FRANC583	ETL Improvements
	06/04/2020	FRANC583	http://jira.ehr.com/browse/CPI-2536
	11/02/2021	FRANC583	http://jira.ehr.com/browse/CPI-6659
**/
CREATE PROCEDURE [dbo].[uspAddCQToDimGroup]
	@ParametersFromTable	BIT = 1,
	@CQTablename			NVARCHAR(100) = 'CQ1',
	@SchemaName				NVARCHAR(100) = '',
	@DimTable				NVARCHAR(100) = '',
	@DimsSchemaName			NVARCHAR(100) = ''
AS
BEGIN
	/*
		First of All let me apologize in advanced for the monstrosity you will encounter below.
		The flat file being given to us seems formatted by the devil himself.
		The code will attempt to convert the data into parent - child relationships.

		Imagine the flat file, different demographic groups with varying amount of hierarchy levels

	*/
	SET NOCOUNT ON;

	DECLARE
		@CQTablenameLocal		NVARCHAR(100) = @CQTablename,
		@SchemaNameLocal		NVARCHAR(100) = @SchemaName,
		@DimTableLocal			NVARCHAR(100) = @DimTable,
		@DimsSchemaNameLocal	NVARCHAR(100) = @DimsSchemaName

	IF @ParametersFromTable = 1
	BEGIN
		SELECT @SchemaNameLocal		= SettingValue FROM mdm.Settings WHERE SettingName = 'StagingSchemaName';
		SELECT @DimTableLocal		= SettingValue FROM mdm.Settings WHERE SettingName = 'DimGroupTable';
		SELECT @DimsSchemaNameLocal = SettingValue FROM mdm.Settings WHERE SettingName = 'DimSchemaName';
	END

	DECLARE @FullCQTable	NVARCHAR(100)	= @SchemaNameLocal		+ '.' + @CQTablenameLocal
	DECLARE @FullDimTable	NVARCHAR(200)	= @DimsSchemaNameLocal	+ '.' + @DimTableLocal

	DECLARE @FlatTable NVARCHAR(100) = @FullCQTable + 'Flat'


	-- Will contain the columns of @tablename
	DECLARE @TblColumnList TABLE
	(
		ID			INT IDENTITY(1,1),
		ColumnName	NVARCHAR(100)
	)

	INSERT INTO @TblColumnList
	SELECT 
		QUOTENAME(c.[name]) AS ColumnName
	FROM sys.columns c
	INNER JOIN sys.tables t ON c.object_id = t.object_id
	WHERE t.[name] = @CQTablenameLocal
		AND SCHEMA_NAME(t.[schema_id]) = @SchemaNameLocal
		AND c.[name] LIKE 'Level%'
	ORDER BY c.column_id asc;

	DECLARE @DistinctLevels NVARCHAR(MAX) = ''

	/**
		This will contain all the distinct contents of the CQ

		Format:

		SELECT DISTINCT [Level 1] AS CodingLabel FROM staging.CQ2 WHERE [Level 1] IS NOT NULL
		UNION
		SELECT DISTINCT [Level 2] AS CodingLabel FROM staging.CQ2 WHERE [Level 2] IS NOT NULL
		UNION
		SELECT DISTINCT [Level 3] AS CodingLabel FROM staging.CQ2 WHERE [Level 3] IS NOT NULL
		*
		*
		*
	**/

	SELECT
		@DistinctLevels = @DistinctLevels + '
		SELECT DISTINCT ' + ColumnName + 'AS CodingLabel FROM ' + @FullCQTable + ' WHERE ' + ColumnName + ' IS NOT NULL
		UNION'
	FROM @TblColumnList

	SET @DistinctLevels = LEFT(@DistinctLevels,LEN(@DistinctLevels) - 5)


	IF OBJECT_ID(N'tempdb..#CodingDetail') IS NOT NULL
		DROP TABLE #CodingDetail;

	CREATE TABLE #CodingDetail
	(
		Detail NVARCHAR(2000)
	);
	-- The distinct Coding Labels
	INSERT INTO #CodingDetail
	EXEC sp_executesql @DistinctLevels;

	DECLARE 
		@MaxID			INT,
		@sqlMaxID		NVARCHAR(500),
		@ParmDefinition NVARCHAR(500);


	SELECT @sqlMaxID = N'SELECT @MaxIDOut = MAX(CodingResponse) FROM ' + @FlatTable;  

	SET @ParmDefinition = N'@MaxIDOut int OUTPUT';

	-- Get the Maximum ID to be used in the loop counter
	EXEC sp_executesql	@sqlMaxID, 
						@ParmDefinition, 
						@MaxIDOut = @MaxID OUTPUT;

	-- This Temporary Table will contain the Coding Response and the Coding Labels
	IF OBJECT_ID(N'tempdb..#All') IS NOT NULL
		DROP TABLE #All;

	CREATE TABLE #All
	(
		DimKey					INT IDENTITY(1,1),
		CodingResponse			INT,
		CodingLabel				NVARCHAR(2000),
		CodingLabelUniquefier	NVARCHAR(2000)
	);

	DECLARE @sqlAll NVARCHAR(MAX) = ''
	/**
		basically, the CQ file already contains the Coding Value for specific coding labels. Like this format:

		Coding Value	CQ	Coding Definition	Level 1					Level 2			Level 3				Level 4		Level 5
		1				2	CQ2:1				Geography (Custom DQ)	SOUTHEAST ASIA	Brunei
		2				2	CQ2:2				Geography (Custom DQ)	SOUTHEAST ASIA	Philippines	Luzon	Region 1
		3				2	CQ2:3				Geography (Custom DQ)	SOUTHEAST ASIA	Philippines	Luzon	Region 2
		4				2	CQ2:4				Geography (Custom DQ)	SOUTHEAST ASIA	Philippines	Luzon	Region 3	Aurora Province
		5				2	CQ2:5				Geography (Custom DQ)	SOUTHEAST ASIA	Philippines	Luzon	Region 3	Bataan

		Here Brunei, Region 1, Region 2, Auorora Province and Bataan already have coding value

		SOUTHEAST ASIA has bo Coding Value

		The query below combines both members

	**/

	SET @sqlAll = '
	INSERT INTO #All
	SELECT
		CodingResponse,
		IIF(CHARINDEX(''|'',CodingLabel) = 0,CodingLabel,LEFT(CodingLabel,CHARINDEX(''|'',CodingLabel) - 1)) AS CodingLabel,
		CodingLabel AS CodingLabelUniquefier
	FROM ' + @FlatTable + ';

	INSERT INTO #All
	SELECT 
		NULL AS CodingResponse,
		IIF(CHARINDEX(''|'',cd.Detail) = 0,cd.Detail,LEFT(cd.Detail,CHARINDEX(''|'',cd.Detail) - 1)) AS CodingLabel,
		cd.Detail AS CodingLabelUniquefier
	FROM #CodingDetail cd
	LEFT JOIN ' + @FlatTable + ' f ON cd.Detail = f.CodingLabel
	WHERE f.CodingLabel IS NULL
	';

	EXEC sp_executesql @sqlAll

	-- Now we convert the Flat tables into Parent Child Relationships

	DECLARE @NumOfColumns	INT = (SELECT COUNT(*) FROM @TblColumnList);
	DECLARE @loopcounter	INT = 1;

	DECLARE 
		@sql		NVARCHAR(MAX) = '',
		@concatsql	NVARCHAR(MAX) = '';

	DECLARE 
		@columnNameChild	NVARCHAR(MAX) = N'',
		@columnNameParent	NVARCHAR(MAX) = N'';

	IF OBJECT_ID(N'tempdb..#ParentChild') IS NOT NULL
		DROP TABLE #ParentChild;

	CREATE TABLE #ParentChild
	(
		CodingResponse				INT,
		CodingLabel					NVARCHAR(2000),
		CodingLabelUniquefier		NVARCHAR(2000),
		ParentCodingResponse		INT,
		ParentCodingLabelUniquefier	NVARCHAR(2000),
		CQNumber					INT
	);

	CREATE CLUSTERED COLUMNSTORE INDEX CCI_ParentChild on #ParentChild;

	/**
		A hack to convert into Parent-Child relationship


		The format of the dynamic SQL is:

		INSERT INTO #ParentChild
		SELECT DISTINCT
			a.CodingResponse,
			a.CodingLabel,
			b.CodingResponse AS ParentCodingResponse,
			cq.CQ AS CQNumber
		FROM staging.CQ2 cq
		INNER JOIN #All a ON cq.[Level 9] = a.CodingLabelUniquefier
		INNER JOIN #All b ON cq.[Level 8] = b.CodingLabelUniquefier


		INSERT INTO #ParentChild
		SELECT DISTINCT
			a.CodingResponse,
			a.CodingLabel,
			b.CodingResponse AS ParentCodingResponse,
			cq.CQ AS CQNumber
		FROM staging.CQ2 cq
		INNER JOIN #All a ON cq.[Level 8] = a.CodingLabelUniquefier
		INNER JOIN #All b ON cq.[Level 7] = b.CodingLabelUniquefier
		*
		*
		So on up to the number of levels the CQ contains

	**/
	WHILE @NumOfColumns >= 1
	BEGIN
		SET @columnNameChild	= (SELECT ColumnName FROM @TblColumnList WHERE ID = @NumOfColumns);
		SET @columnNameParent	= (SELECT ColumnName FROM @TblColumnList WHERE ID = @NumOfColumns - 1);

		SET @sql = '
		INSERT INTO #ParentChild
		SELECT DISTINCT
			a.CodingResponse,
			a.CodingLabel,
			a.CodingLabelUniquefier,
			b.CodingResponse AS ParentCodingResponse,
			b.CodingLabelUniquefier AS ParentCodingLabelUniquefier,
			cq.CQ AS CQNumber
		FROM ' + @FullCQTable + ' cq
		INNER JOIN #All a ON cq.' + @columnNameChild + ' = a.CodingLabelUniquefier
		INNER JOIN #All b ON cq.' + @columnNameParent + ' = b.CodingLabelUniquefier
		';
		EXEC sp_executesql @sql;
		SET @NumOfColumns = @NumOfColumns - 1;
	END;

	-- Now we add the root
	DECLARE 
		@sqlroot NVARCHAR(MAX) = '';

	SET @columnNameParent = (SELECT ColumnName FROM @TblColumnList WHERE ID = 1);

	SET @sqlroot = '
	INSERT INTO #ParentChild
	SELECT DISTINCT
		b.CodingResponse,
		b.CodingLabel,
		b.CodingLabelUniquefier,
		NULL				AS ParentCodingResponse,
		NULL				AS ParentCodingLabelUniquefier,
		cq.CQ				AS CQNumber
	FROM ' + @FullCQTable + ' cq
	INNER JOIN #All b ON cq.' + @columnNameParent + ' = b.CodingLabelUniquefier'

	EXEC sp_executesql @sqlroot



	-- Insert Parent CQ Name to staging.CQList
	-- This is important. Removing this statement will cause sleepless nights, rather, weeks.
	-- This thing here is the basis for the OLAP Cube dynamic dimensions. The code inserts a Dimension to the table containing the list of dimensions(Coding Group) used by the tenant


	DECLARE @MaxDimNo INT = ISNULL((SELECT MAX(DimNumber) FROM staging.CQList WHERE CQNumber < 1000),0);
	SET @MaxDimNo += 1;

	-- CPA-608, Set the Dimension entry as Active in staging.CQList
	DECLARE @sqlDims NVARCHAR(MAX) = '
	;WITH newitems AS
	(
		SELECT
			d.CQNumber,
			d.CodingLabel AS CQName,
			dbo.svfRemoveNonAlphaCharacters(d.CodingLabel) as dimTable
		FROM
		(
			SELECT DISTINCT
				cq.CQ AS CQNumber,
				IIF(CHARINDEX(''|'',b.CodingLabel) = 0,b.CodingLabel,LEFT(b.CodingLabel,CHARINDEX(''|'',b.CodingLabel) - 1)) AS CodingLabel
			FROM ' + @FullCQTable + ' cq
			INNER JOIN #All b ON cq.' + @columnNameParent + ' = b.CodingLabelUniquefier
		)d
		LEFT JOIN staging.CQList l ON d.CodingLabel = l.CQName
		WHERE l.dimTable IS NULL
	)
	INSERT INTO staging.CQList
	(
		CQNumber,
		CQName,
		DimNumber,
		dimTable,
		IsCurrentlyUsed,
		Caption
	)
	SELECT
		CQNumber,
		CQName,
		' + CAST(@MaxDimNo AS NVARCHAR(4)) + N',
		dimTable,
		1,
		''Dim'' + CAST(' + CAST(@MaxDimNo AS NVARCHAR(4)) + N' AS NVARCHAR(4))
	FROM newitems;';

	EXEC sp_executesql @sqlDims;

	SET @sqlDims  = N'
	;WITH newitems AS
	(
		SELECT DISTINCT
			cq.CQ AS CQNumber,
			IIF(CHARINDEX(''|'',b.CodingLabel) = 0,b.CodingLabel,LEFT(b.CodingLabel,CHARINDEX(''|'',b.CodingLabel) - 1)) AS CQName
		FROM ' + @FullCQTable + ' cq
		INNER JOIN #All b ON cq.' + @columnNameParent + ' = b.CodingLabelUniquefier
	)
	SELECT CQName
	FROM newitems;';

	DECLARE @cqnamecontainer TABLE
	(
		CQName NVARCHAR(1000)
	);
	INSERT INTO @cqnamecontainer
	EXEC sp_executesql @sqlDims;

	DECLARE @CQName NVARCHAR(MAX) = (SELECT TOP 1 CQName FROM @cqnamecontainer);

	IF @CQName = 'Turnover'
	BEGIN
		UPDATE ds 
		SET ds.HasTurnoverData = 1
		FROM dbo.dimSurvey ds
		INNER JOIN  staging.SurveyMetadata stg ON ds.SurveyYear = stg.SurveyYear
			AND ds.SurveyVersion = stg.SurveyVersion
	END;

	-- Handle Change in Organization

	DECLARE 
		@ParentCoding NVARCHAR(2000) = (SELECT CodingLabelUniquefier FROM #ParentChild WHERE ParentCodingLabelUniquefier IS NULL);

	IF (SELECT COUNT(CodingLabelUniquefier) FROM #ParentChild WHERE ParentCodingLabelUniquefier = @ParentCoding) = 1
	BEGIN

		DECLARE
			@FirstLevel NVARCHAR(2000) = (SELECT CodingLabelUniquefier FROM #ParentChild WHERE ParentCodingLabelUniquefier = @ParentCoding);

		IF (Select CodingLabelUniquefier from dbo.DimGroup WHERE ParentCodingLabelUniquefier = @ParentCoding AND IsActive = 1) <> @FirstLevel
		BEGIN
			UPDATE dbo.dimGroup SET IsActive = 0 WHERE ParentCQName = @CQName AND IsActive = 1 AND ParentGroupKey IS NOT NULL; 
		END
	END;
	-- Updates If CQ is used
	SET @sqlDims = '
	UPDATE staging.CQList
	SET IsCurrentlyUsed = 1
	WHERE dimTable = 
	(
		SELECT TOP 1 dimTable 
		FROM 
		(
			SELECT
					d.CQNumber,
					d.CodingLabel AS CQName,
					dbo.svfRemoveNonAlphaCharacters(d.CodingLabel) as dimTable
				FROM
				(
					SELECT DISTINCT
						cq.CQ AS CQNumber,
						IIF(CHARINDEX(''|'',b.CodingLabel) = 0,b.CodingLabel,LEFT(b.CodingLabel,CHARINDEX(''|'',b.CodingLabel) - 1)) AS CodingLabel
					FROM ' + @FullCQTable + ' cq
					INNER JOIN #All b ON cq.' + @columnNameParent + ' = b.CodingLabelUniquefier
				)d
				INNER JOIN staging.CQList l ON d.CodingLabel = l.CQName
		)A
	);'

	EXEC sp_executesql @sqlDims;



	-- Updates If CQNumber changed
	SET @sqlDims = '
	;WITH updates AS
	(
		SELECT
			d.CQNumber,
			d.CodingLabel AS CQName,
			dbo.svfRemoveNonAlphaCharacters(d.CodingLabel) as dimTable
		FROM
		(
			SELECT DISTINCT
				cq.CQ AS CQNumber,
				IIF(CHARINDEX(''|'',b.CodingLabel) = 0,b.CodingLabel,LEFT(b.CodingLabel,CHARINDEX(''|'',b.CodingLabel) - 1)) AS CodingLabel
			FROM ' + @FullCQTable + ' cq
			INNER JOIN #All b ON cq.' + @columnNameParent + ' = b.CodingLabelUniquefier
		)d
	)
	UPDATE cq
	SET
		cq.CQNumber = u.CQNumber
	FROM staging.CQList cq
	INNER JOIN updates u ON cq.CQName = u.CQName';

	EXEC sp_executesql @sqlDims;


	DECLARE @sqldiminsert NVARCHAR(MAX) = '';

	DECLARE
		@SurveyYear		INT,
		@SurveyVersion	INT;

	-- Get Survey Metadata
	SELECT
		@SurveyYear		= SurveyYear,
		@SurveyVersion	= SurveyVersion
	FROM staging.SurveyMetadata;

	/*
		Why not use MERGE?

		MERGE is slow especially when using Columnstore Indexes. Heck it is faster to implement the logic using INSERT and UPDATES

		dimGroup implements an SCD Type 2 Dimension. We match using CodingLabelUniquefier and CQNumber.
		If the Parent Coding Response Changes, the old record will be expired. A new record will be created that will capture the change.

		Of course new Records based on the matching criteria will be inserted.
	*/

	-- Updates
	IF OBJECT_ID(N'tempdb..#ParentChild_Updates') IS NOT NULL
		DROP TABLE #ParentChild_Updates;

	CREATE TABLE #ParentChild_Updates
	(
		GroupKey					INT,
		CodingResponse				INT,
		CodingLabel					NVARCHAR(2000),
		CodingLabelUniquefier		NVARCHAR(2000),
		ParentCodingResponse		INT,
		ParentCodingLabelUniquefier	NVARCHAR(2000),
		CQNumber					INT
	);

	CREATE CLUSTERED COLUMNSTORE INDEX CCI_ParentChild_Updates on #ParentChild_Updates;


	INSERT INTO #ParentChild_Updates
	SELECT 
		dim.GroupKey AS GroupKey,
		temp.CodingResponse,
		temp.CodingLabel,
		temp.CodingLabelUniquefier,
		temp.ParentCodingResponse,
		temp.ParentCodingLabelUniquefier AS ParentCodingLabelUniquefier,
		temp.CQNumber
	FROM #ParentChild temp
	INNER JOIN dbo.dimGroup dim ON dim.CodingResponseID = temp.CodingResponse
		AND dim.CQNumber = temp.CQNumber
	WHERE 
	(
		dim.ParentCodingLabelUniquefier <> temp.ParentCodingLabelUniquefier 
		OR dim.CodingLabelUniquefier <> temp.CodingLabelUniquefier
	)
	AND dim.IsActive = 1;

	-- Expire Old rows
	UPDATE dim
	SET 
		dim.IsActive		= 0,
		dim.LastChangedBy	= SYSTEM_USER,
		dim.LastChangeDate	= GETDATE(),
		dim.EndDate			= GETDATE()
	FROM dbo.dimGroup dim
	INNER JOIN #ParentChild_Updates u ON dim.GroupKey = u.GroupKey
		AND dim.CQNumber = u.CQNumber

	-- iNSERT NEW ROWS
	INSERT INTO dbo.dimGroup
	SELECT
		CodingResponse				AS CodingResponseID,
		CodingLabel					AS CodingLabel,
		@CQName						AS ParentCQName,
		ParentCodingResponse		AS ParentCodingResponseID,
		NULL						AS ParentGroupKey,
		CQNumber					AS CQNumber,
		CodingLabelUniquefier		AS CodingLabelUniquefier,
		ParentCodingLabelUniquefier	AS ParentCodingLabelUniquefier,
		SYSTEM_USER					AS LastChangedBy,
		GETDATE()					AS LastChangeDate,
		GETDATE()					AS StartDate,
		'12/31/9999'				AS EndDate,
		1							AS IsActive
	FROM #ParentChild_Updates;

	-- New Items
	;WITH newitems AS
	(
		SELECT 
			temp.* 
		FROM #ParentChild temp
		LEFT JOIN 
		(
			SELECT * FROM dbo.dimGroup WHERE IsActive = 1
		)dim ON dim.CodingLabelUniquefier = temp.CodingLabelUniquefier
			AND dim.CQNumber = temp.CQNumber
		WHERE dim.CodingLabelUniquefier IS NULL 
	)
	INSERT INTO dbo.dimGroup
	SELECT
		CodingResponse			AS CodingResponseID,
		CodingLabel				AS CodingLabel,
		@CQName					AS ParentCQName,
		ParentCodingResponse	AS ParentCodingResponseID,
		NULL					AS ParentGroupKey,
		CQNumber				AS CQNumber,
		CodingLabelUniquefier	AS CodingLabelUniquefier,
		ParentCodingLabelUniquefier	AS ParentCodingLabelUniquefier,
		SYSTEM_USER				AS LastChangedBy,
		GETDATE()				AS LastChangeDate,
		GETDATE()				AS StartDate,
		'12/31/9999'			AS EndDate,
		1						AS IsActive
	FROM newitems;



	--Clean Up
	DECLARE @drop NVARCHAR(300) = '';

	SET @drop = '
	DROP TABLE ' + @FlatTable + ';
	DROP TABLE ' + @FullCQTable + ';';

	EXEC sp_executesql @drop;
END;
GO
