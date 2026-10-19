@{
    IncludeDefaultRules = $true
    ExcludeRules = @('PSUseBOMForUnicodeEncodedFile', 'PSAvoidUsingWriteHost')
    Rules = @{
        PSUseConsistentIndentation = @{
            Enable = $true
            Kind = 'space'
            IndentationSize = 4
            PipelineIndentation = 'IncreaseIndentationForFirstPipeline'
        }
        PSUseConsistentWhitespace = @{
            Enable = $true
            CheckOpenBrace = $true
            CheckInnerBrace = $true
            CheckPipe = $true
            CheckSeparator = $true
            CheckParameter = $true
        }
        PSPlaceOpenBrace = @{ Enable = $true; OnSameLine = $true }
        PSPlaceCloseBrace = @{ Enable = $true; NoEmptyLineBefore = $true }
    }
}
