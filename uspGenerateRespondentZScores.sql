/**
	Summary:
		Calculate the Opinion and Category ZScores for the whole Survey
	Example:
		EXEC corr.uspGenerateRespondentZScores
		
	Returns: None


	Change History
	==============================================================
	03/27/2020	FRANC583	Initial Version
	08/11/2020	FRANC583	Add Precalculation for Category Category Correlation
	02/19/2021	FRANC583	Single Fact Table	
**/
CREATE PROCEDURE [corr].[uspGenerateRespondentZScores]
AS
BEGIN
	SET NOCOUNT ON;

	-- Precalculation
	EXEC dbo.uspPrecalculateCatToCatCorrelation;

END;
GO