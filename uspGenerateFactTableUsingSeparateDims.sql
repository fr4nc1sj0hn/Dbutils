/**
	Summary:
		Generates the Fact Table for the individual Dimensions from the CQs
	Example:
		EXEC dbo.uspGenerateFactTableUsingSeparateDims

	Returns: None
	
	Change History
	==============================================================
	05/18/2018	FRANC583	Initial Version
	01/17/2019	FRANC583	CPA-608, CPA-268
	02/04/2019	FRANC583	CPA-619
	10/02/2019	FRANC583	CPI-157
	10/29/2019	FRANC583	Make this a wrapper Stored Procedure Instead
	11/24/2020	FRANC583	CPI-3750 Business Metrics ETL
	02/19/2021	FRANC583	Single Fact Table
**/	
CREATE PROCEDURE [dbo].[uspGenerateFactTableUsingSeparateDims]
AS
BEGIN
	SET NOCOUNT ON;


	-- Check if Date Information is loaded in staging.CQList OR If the Table staging.RespondentDateInformation is loaded
	IF EXISTS (SELECT 1 FROM staging.CQList WHERE CQNumber >= 1000) OR EXISTS (SELECT 1 FROM sys.tables WHERE [name] = 'RespondentDateInformation')
	BEGIN
		EXEC dbo.uspGenerateDynamicFactTableFavorableDates;
		--EXEC dbo.uspGenerateDynamicFactTableRawDates;
	END
	ELSE
	BEGIN
		EXEC dbo.uspGenerateDynamicFactTableFavorable;
		--EXEC dbo.uspGenerateDynamicFactTableRaw;
	END
	EXEC [corr].[uspGenerateRespondentZScores];
	-- Business Metrics
	
	EXEC dbo.uspGenerateFactBusinessMetrics;

	UPDATE mdm.Settings
	SET SettingValue = 0
	WHERE SettingName = 'InitialLoad'

END;
GO