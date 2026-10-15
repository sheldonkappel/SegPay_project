<#
.SYNOPSIS
    Generates the gold type-1 dimension load procedures (one .sql file each)
    from the specifications below.

.DESCRIPTION
    Every type-1 dimension loads the same way - only the columns differ - so
    the procedures are generated from one template instead of copied by hand.
    To change a dimension: edit its entry in $Dims (or the template), run this
    script, review the diff, then deploy the regenerated file.

        .\New-Type1DimProcedures.ps1

    dim_merchant (type 2, keeps history) and dim_date are written by hand.
#>
$OutDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'procedures'

$Dims = @(
    @{ Name = 'dim_site'; Key = 'site_key'; Bk = @('site_id'); UnknownBk = @('-1')
       Source = 'silver.sites'
       Select = 'site_id, site_name, site_url, category, status, launch_date, billing_descriptor, merchant_id'
       Attrs  = @('site_name','site_url','category','status','launch_date','billing_descriptor','merchant_id')
       UnknownCols = @{ site_name = "N'Unknown'" }
       Purpose = 'One row per site (website a merchant sells through).'
       Notes = @('merchant_id is the owner per the sites file. 12 sites list merchants MRC-00201 - MRC-00205',
                 'while their transactions name another merchant (see silver.usp_load_sites); facts take the',
                 'merchant from the transaction, not from here.') }

    @{ Name = 'dim_merchant_account'; Key = 'merchant_account_key'; Bk = @('mid'); UnknownBk = @("'Unknown'")
       Source = 'silver.merchant_accounts'
       Select = 'mid, merchant_id, acquirer_name, currency_group, mcc, effective_from, status'
       Attrs  = @('merchant_id','acquirer_name','currency_group','mcc','effective_from','status')
       UnknownCols = @{ acquirer_name = "'Unknown'" }
       Purpose = 'One row per merchant processing account (MID) at an acquiring bank.'
       Notes = @() }

    @{ Name = 'dim_package'; Key = 'package_key'; Bk = @('package_id'); UnknownBk = @('-1')
       Source = 'silver.packages'
       Select = 'package_id, package_name, site_id, billing_model, initial_price, rebill_price, currency, trial_days, rebill_period_days, status'
       Attrs  = @('package_name','site_id','billing_model','initial_price','rebill_price','currency','trial_days','rebill_period_days','status')
       UnknownCols = @{ package_name = "N'Unknown'" }
       Purpose = 'One row per package (price point: one-time, recurring or trial).'
       Notes = @('About 350 transactions reference a package not in silver.packages; they map to Unknown.') }

    @{ Name = 'dim_customer'; Key = 'customer_key'; Bk = @('customer_id'); UnknownBk = @("'Unknown'")
       Source = 'silver.customers'
       Select = 'customer_id, country, created_at AS created_date, marketing_opt_in'
       Attrs  = @('country','created_date','marketing_opt_in')
       UnknownCols = @{}
       Purpose = 'One row per customer (cardholder account).'
       Notes = @('Personal data (email, postal code) is deliberately left in silver.') }

    @{ Name = 'dim_affiliate'; Key = 'affiliate_key'; Bk = @('affiliate_id'); UnknownBk = @("'Unknown'")
       Source = 'silver.affiliates'
       Select = 'affiliate_id, affiliate_name, affiliate_type, commission_pct, status, join_date, country, payout_method'
       Attrs  = @('affiliate_name','affiliate_type','commission_pct','status','join_date','country','payout_method')
       UnknownCols = @{ affiliate_name = "N'Unknown / Direct'" }
       Purpose = 'One row per affiliate (traffic partner earning commission).'
       Notes = @('Facts with no affiliate (direct / organic traffic) map to key -1, labelled Unknown / Direct.') }

    @{ Name = 'dim_card_bin'; Key = 'card_bin_key'; Bk = @('bin'); UnknownBk = @("'Unknown'")
       Source = 'silver.bin_reference'
       Select = 'bin, card_brand, card_type, card_category, issuer_name, issuer_country'
       Attrs  = @('card_brand','card_type','card_category','issuer_name','issuer_country')
       UnknownCols = @{ issuer_name = "N'Unknown'" }
       Purpose = 'One row per card BIN (first 6 digits): brand, card type, tier, issuing bank and country.'
       Notes = @('silver.bin_reference covers 243 BINs; ~14,800 transactions use other BINs and map to Unknown.') }

    @{ Name = 'dim_response_code'; Key = 'response_code_key'; Bk = @('response_code'); UnknownBk = @("'Unknown'")
       Source = 'silver.response_codes r LEFT JOIN ref.response_code_class c ON c.response_code = r.response_code'
       Select = "r.response_code, r.description, c.response_group, c.decline_type, CAST(CASE WHEN c.response_group = 'Approved' THEN 1 ELSE 0 END AS BIT) AS is_approved"
       Attrs  = @('description','response_group','decline_type','is_approved')
       UnknownCols = @{ description = "'Unknown'" }
       Purpose = 'One row per authorization response code, classed Approved / Soft decline / Hard decline (ref.response_code_class).'
       Notes = @('Edit ref.response_code_class to change which declines count as soft (retry) or hard.') }

    @{ Name = 'dim_chargeback_reason'; Key = 'chargeback_reason_key'; Bk = @('network','reason_code'); UnknownBk = @("'Unknown'","'Unknown'")
       Source = 'silver.chargeback_reason_codes'
       Select = 'network, reason_code, description, category'
       Attrs  = @('description','category')
       UnknownCols = @{ description = "N'Unknown'" }
       Purpose = 'One row per card-network chargeback reason code (network + code).'
       Notes = @() }
)

foreach ($d in $Dims) {
    $name = $d.Name; $key = $d.Key
    $bkJoin   = ($d.Bk | ForEach-Object { "t.$_ = s.$_" }) -join ' AND '
    $bkCols   = $d.Bk -join ', '
    $attrCols = $d.Attrs -join ', '
    $sAttrs   = ($d.Attrs | ForEach-Object { "s.$_" }) -join ', '
    $tAttrs   = ($d.Attrs | ForEach-Object { "t.$_" }) -join ', '
    $setList  = ($d.Attrs | ForEach-Object { "$_ = s.$_" }) -join ', '
    $insCols  = (@($d.Bk) + @($d.Attrs)) -join ', '
    $insVals  = ((@($d.Bk) + @($d.Attrs)) | ForEach-Object { "s.$_" }) -join ', '
    $unkCols  = @($key) + @($d.Bk) + @($d.UnknownCols.Keys)
    $unkVals  = @('-1') + @($d.UnknownBk) + @($d.UnknownCols.Values)
    $notes    = if ($d.Notes.Count) { "`r`n   Notes`r`n   -----`r`n" + (($d.Notes | ForEach-Object { "     $_" }) -join "`r`n") + "`r`n" } else { '' }

    $sql = @"
/* =====================================================================
   Procedure : gold.usp_load_$name
   Source    : $($d.Source.Split(' ')[0])
   Target    : gold.$name   (type 1 - overwritten on change, no history)
   Load type : Incremental MERGE - new rows inserted, changed rows updated,
               rows gone from the source flagged is_deleted = 1 (never deleted,
               facts may still point at them).

   Purpose
   -------
   $($d.Purpose)
   $key -1 = Unknown.
$notes
   Generated by SQL\gold\tools\New-Type1DimProcedures.ps1 - edit the
   specification there and regenerate rather than editing this file.

   Usage
   -----
     EXEC gold.usp_load_$name;
   ===================================================================== */
CREATE OR ALTER PROCEDURE gold.usp_load_$name
    @run_id UNIQUEIDENTIFIER = NULL     -- set by gold.usp_load_all; NULL when run on its own
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @ProcName  SYSNAME      = OBJECT_SCHEMA_NAME(@@PROCID) + N'.' + OBJECT_NAME(@@PROCID),
            @Target    SYSNAME      = N'gold.$name',
            @StartedAt DATETIME2(3) = SYSUTCDATETIME(),
            @Source    INT,
            @Total     INT,
            @Metrics   NVARCHAR(MAX),
            @Err       NVARCHAR(4000);
    DECLARE @changes TABLE (action NVARCHAR(10), was_deleted BIT, is_deleted BIT);

    BEGIN TRY
        IF OBJECT_ID(@Target, N'U') IS NULL
            THROW 50001, N'gold.$name does not exist - run SQL\gold\01_gold_tables.sql first.', 1;

        SELECT @Source = COUNT(*) FROM $($d.Source.Split(' ')[0]);

        BEGIN TRAN;

        -- Unknown member
        IF NOT EXISTS (SELECT 1 FROM gold.$name WHERE $key = -1)
        BEGIN
            SET IDENTITY_INSERT gold.$name ON;
            INSERT gold.$name ($($unkCols -join ', '), load_run_id)
            VALUES ($($unkVals -join ', '), @run_id);
            SET IDENTITY_INSERT gold.$name OFF;
        END

        MERGE gold.$name WITH (HOLDLOCK) AS t
        USING (SELECT $($d.Select)
               FROM $($d.Source)) AS s
           ON $bkJoin
        WHEN MATCHED AND (t.is_deleted = 1 OR EXISTS (SELECT $sAttrs
                                                     EXCEPT
                                                     SELECT $tAttrs))
            THEN UPDATE SET $setList,
                            is_deleted = 0, updated_at = SYSUTCDATETIME(), load_run_id = @run_id
        WHEN NOT MATCHED BY TARGET
            THEN INSERT ($insCols, load_run_id)
                 VALUES ($insVals, @run_id)
        WHEN NOT MATCHED BY SOURCE AND t.$key <> -1 AND t.is_deleted = 0
            THEN UPDATE SET is_deleted = 1, updated_at = SYSUTCDATETIME(), load_run_id = @run_id
        OUTPUT `$action, deleted.is_deleted, inserted.is_deleted INTO @changes;

        COMMIT;

        SELECT SourceRows     = @Source,
               Inserted       = (SELECT COUNT(*) FROM @changes WHERE action = 'INSERT'),
               Updated        = (SELECT COUNT(*) FROM @changes WHERE action = 'UPDATE' AND is_deleted = 0),
               FlaggedDeleted = (SELECT COUNT(*) FROM @changes WHERE action = 'UPDATE' AND is_deleted = 1 AND was_deleted = 0),
               TotalRows      = (SELECT COUNT(*) FROM gold.$name WHERE $key <> -1)
        INTO #summary;

        SELECT @Total = TotalRows FROM #summary;
        SET @Metrics = (SELECT * FROM #summary FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

        EXEC audit.usp_log_load @run_id = @run_id, @proc_name = @ProcName, @target_table = @Target,
             @started_at = @StartedAt, @status = 'Succeeded', @rows_read = @Source, @rows_loaded = @Total, @metrics = @Metrics;

        SELECT * FROM #summary;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        SET @Err = ERROR_MESSAGE();
        EXEC audit.usp_log_load @run_id = @run_id, @proc_name = @ProcName, @target_table = @Target,
             @started_at = @StartedAt, @status = 'Failed', @error_message = @Err;
        THROW;
    END CATCH
END
GO
"@
    $path = Join-Path $OutDir "usp_load_$name.sql"
    [IO.File]::WriteAllText($path, $sql.Replace("`r`n", "`n").Replace("`n", "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
    "generated $path"
}
