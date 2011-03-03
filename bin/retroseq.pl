#!/usr/bin/env perl
# 
# Author:       tk2
# Maintainer:   tk2
# Created:      Fri Sep 10 14:07:53 BST 2010 @588 /Internet Time/
# Updated:      Fri Sep 10 14:08:03 BST 2010 @588 /Internet Time/

=pod
Status: 
Should work and compile
Test: validation and genotyping steps
Todo:
Calling of heterozygotes is not handled right now
=cut

use Carp;
use strict;
use warnings;
use Getopt::Long;
use Cwd;
use File::Basename;
use File::Path qw(make_path);

use lib dirname(__FILE__).'/../lib/all';
use Vcf;

my $VERSION = 0.1;

my $DEFAULT_ID = 90;
my $DEFAULT_LENGTH = 36;
my $DEFAULT_ANCHORQ = 30;
my $DEFAULT_MAX_DEPTH = 200;
my $DEFAULT_READS = 5;
my $DEFAULT_MIN_GENOTYPE_READS = 3;
my $MAX_READ_GAP_IN_REGION = 2000;
my $GENOTYPE_READS_WINDOW = 5000;

#-validation fixed values
my $WINDOW_SIZE = 600;
my $MIN_HIT_LENGTH = 25;
my $MIN_BREAK_SIZE = 25;
my $MIN_DIST_TO_BREAK = 50;

my $HEADER = qq[#retroseq v$VERSION\n#START_CANDIDATES];
my $FOOTER = qq[#END_CANDIDATES];

my $BAMFLAGS = 
{
    'paired_tech'    => 0x0001,
    'read_paired'    => 0x0002,
    'unmapped'       => 0x0004,
    'mate_unmapped'  => 0x0008,
    'reverse_strand' => 0x0010,
    'mate_reverse'   => 0x0020,
    '1st_in_pair'    => 0x0040,
    '2nd_in_pair'    => 0x0080,
    'not_primary'    => 0x0100,
    'failed_qc'      => 0x0200,
    'duplicate'      => 0x0400,
};

#TESTING
#_outputCalls('18369.refined_calls.4.tab', 'H12', '/lustre/scratch102/projects/mouse/ref/NCBIM37_um.fa', 'test.vcf');
#exit;
my ($discover, $call, $genotype, $bam, $bams, $ref, $eRef, $length, $id, $output, $anchorQ, $input, $reads, $depth, $cleanup, $chr, $tmpdir, $help);

GetOptions
(
    #actions
    'discover'      =>  \$discover,
    'call'          =>  \$call,
    'genotype'      =>  \$genotype,
    
    #parameters
    'bam=s'         =>  \$bam,
    'bams=s'        =>  \$bams,
    'eref=s'        =>  \$eRef,
    'ref=s'         =>  \$ref,
    'len=s'         =>  \$length,
    'id=s'          =>  \$id,
    'q=s'           =>  \$anchorQ,
    'output=s'      =>  \$output,
    'input=s'       =>  \$input,
    'reads=s'       =>  \$reads,
    'depth=s'       =>  \$depth,
    'cleanup=s'     =>  \$cleanup,
    'chr=s'         =>  \$chr,
    'tmp=s'         =>  \$tmpdir,
    'h|help'        =>  \$help,
);

print <<MESSAGE;

RetroSeq: A tool for discovery and genotyping of transposable elements from short read alignments
Version: $VERSION
Author: Thomas Keane (thomas.keane\@sanger.ac.uk)

MESSAGE

my $USAGE = <<USAGE;
Usage: $0 -<command> options

            -discover       Takes a BAM and a set of reference TE (fasta) and calls candidate supporting read pairs (BED output)
            -call           Takes multiple output of discovery stage (can be multiple files of same sample e.g. multiple lanes) and a BAM and outputs a VCF of TE calls
            -genotype       Input is a VCF of TE calls and a set of sample BAMs, output is a new VCF with genotype calls for new samples
            
NOTE: $0 requires samtools, ssaha2, unix sort to be in the default path

USAGE

( $discover || $call || $help) or die $USAGE;

if( $discover )
{
    ( $bam && $eRef && $output ) or die <<USAGE;
Usage: $0 -discover -bam <string> -eref <string> -output <string> [-q <int>] [-id <int>] [-len <int> -clean <yes/no>]
    
    -bam        BAM file of paired reads mapped to reference genome
    -eref       Fasta reference set of transposons
    -output     Output file to store candidate supporting reads (required for calling step)
    [-cleanup   Remove intermediate output files (yes/no). Default is yes.]
    [-q         Minimum mapping quality for a read mate that anchors the insertion call. Default is 30. Parameter is optional.]
    [-id        Minmum percent ID for a match of a read to the transposon references. Default is 90.]
    [-len       Miniumum length of a hit to the transposon references. Default is 36bp.]
    
USAGE
    
    croak qq[Cant find BAM: $bam] unless -f $bam;
    croak qq[Cant find TE fasta: $eRef] unless -f $eRef;
    
    #$chr = defined( $chr ) ? $chr : 'all';
    $anchorQ = defined( $anchorQ ) && $anchorQ > -1 ? $anchorQ : $DEFAULT_ANCHORQ;
    $id = defined( $id ) && $id < 101 && $id > 0 ? $id : $DEFAULT_ID;
    $length = defined( $length ) && $length > 25 ? $length : $DEFAULT_LENGTH;
    my $clean = defined( $cleanup ) && $cleanup eq 'no' ? 0 : 1;
    
    print qq[\nMin anchor quality: $anchorQ\nMin percent identity: $id\nMin length for hit: $length\n\n];

    #test for samtools
    _checkBinary( q[samtools] );
    
    _findCandidates( $bam, $eRef, $id, $length, $anchorQ, $output, $clean );
}
elsif( $call )
{
    ( $bam && $input && $ref && $output ) or die <<USAGE;
Usage: $0 -call -bam <string> -input <string> -ref <string> -output <string> [-cleanup -reads <int> -depth <int>]

    -bam            BAM file of paired reads mapped to reference genome
    -input          Either a single output file from the dicover stage OR a file of file names (e.g. output from multiple lanes)
    -ref            Fasta of reference genome
    -output         Output file name (VCF)
    [-depth         It is the minimum mapping quality for a read mate that anchors the insertion call. Default is 30. Parameter is optional.]
    [-reads         It is the minimum number of reads required to make a call. Default is 5. Parameter is optional.]
    [-q             Minimum mapping quality for a read mate that anchors the insertion call. Default is 30. Parameter is optional.]
    [-cleanup       Remove intermediate output files (yes/no). Default is yes.]
    
USAGE
    
    croak qq[Cant find BAM: $bam] unless -f $bam;
    croak qq[Cant find BAM index: $bam.bai] unless -f $bam.qq[.bai];
    croak qq[Cant find input: $input] unless -f $input;
    croak qq[Cant find reference genome fasta: $ref] unless -f $ref;
    croak qq[Cant find reference genome index - please index your reference file with samtools faidx] unless -f qq[$ref.fai];
    
    $reads = defined( $reads ) && $reads =~ /^\d+$/ && $reads > -1 ? $reads : $DEFAULT_READS;
    $depth = defined( $depth ) && $depth =~ /^\d+$/ && $depth > -1 ? $depth : $DEFAULT_MAX_DEPTH;
    $anchorQ = defined( $anchorQ ) && $anchorQ > -1 ? $anchorQ : $DEFAULT_ANCHORQ;
    my $clean = defined( $cleanup ) && $cleanup eq 'no' ? 0 : 1;
    
    #test for samtools
    _checkBinary( q[samtools] );
    
    _findInsertions( $bam, $input, $ref, $output, $reads, $depth, $anchorQ, $clean );
}
elsif( $genotype )
{
    ( $bams && $input && $eRef && $reads && $cleanup && $tmpdir && $output ) or die <<USAGE;
Usage: $0 -genotype -bams <string> -input <string> -eref <string> -output <string> [-cleanup -reads <int> -chr <string> -tmpdir <string>]
    
    -bams           File of BAM file names (one per sample to be genotyped)
    -input          VCF file of TE calls
    -eref           Fasta of TE reference genome
    -output         Output VCF file (will be annotated with new genotype calls)
    [-cleanup       Remove intermediate output files (yes/no). Default is yes.]
    [-reads         Minimum number of reads required for a genotype calls. Default is 3.]
    [-chr           Validate the calls from a single chromosome only. Default is all chromosomes.]
    [-tmpdir        Root of temporary directory for intermediate files. Default is cwd.]
    [-q             Minimum mapping quality for a read mate that anchors the insertion call. Default is 30.]
    [-id            Minmum percent ID for a match of a read to the transposon references. Default is 90.]
    [-len           Miniumum length of a hit to the transposon references. Default is 36bp.]
    
USAGE
    
    croak qq[Cant find BAM fofn: $bams] unless -f $bams;
    croak qq[Cant find input: $input] unless -f $input;
    croak qq[Cant find TE reference genome fasta: $eRef] unless -f $eRef;
    
    my $clean = defined( $cleanup ) && $cleanup eq 'no' ? 0 : 1;
    $reads = defined( $reads ) && $reads =~ /^\d+$/ ? $reads > -1 : $DEFAULT_MIN_GENOTYPE_READS;
    $chr = defined( $chr ) ? $chr : 'all';
    $anchorQ = defined( $anchorQ ) && $anchorQ > -1 ? $anchorQ : $DEFAULT_ANCHORQ;
    $id = defined( $id ) && $id < 101 && $id > 0 ? $id : $DEFAULT_ID;
    $length = defined( $length ) && $length > 25 ? $length : $DEFAULT_LENGTH;
    $tmpdir = defined( $tmpdir ) && -d $tmpdir ? $tmpdir : getcwd();
    
#    _genotype( $bams, $input, $eRef, $reads, $chr, $anchorQ, $id, $length, $tmpdir, $output, $clean );
}
else
{
    print qq[You did not specify an action!\n\n$USAGE];
    exit;
}

sub _findCandidates
{
    my $bam = shift;
    my $eref = shift;
    my $id = shift;
    my $length = shift;
    my $minAnchor = shift;
    my $output = shift;
    my $clean = shift;
    
    #test for ssaha2
    _checkBinary( q[ssaha2] );
    
    my %candidates = %{ _getCandidateTEReadNames($bam, undef, undef, undef, $minAnchor ) };
    
    open( my $ffh, qq[>$$.candidates.fasta] ) or die qq[ERROR: Failed to create fasta file: $!\n];
    open( my $afh, qq[>$$.candidate_anchors.bed] ) or die qq[ERROR: Failed to create anchors file: $!\n];
    
    #now go and get the reads from the bam (annoying have to traverse through the bam a second time - but required for reads where the mate is aligned distantly)
    #also dump out their mates as will need these later as anchors
    open( my $bfh, qq[samtools view $bam |] ) or die $!;
    my $currentChr = '';
    while( my $sam = <$bfh> ) 
    {
        chomp( $sam );
        my @s = split( /\t/, $sam );
        my $name = $s[ 0 ];
        my $flag = $s[ 1 ];
        my $ref = $s[ 2 ];
        if( $candidates{ $name } )
        {
            #       read is 1st in pair                looking for 1st in pair      read in 2nd in pair                     looking for second
            if( ($flag & $$BAMFLAGS{'1st_in_pair'}) && $candidates{ $name } == 1 || ($flag & $$BAMFLAGS{'2nd_in_pair'}) && $candidates{ $name } == 2 )
            {
                my $seq = $s[ 9 ];
                print $ffh qq[>$name\n$seq\n];
            }
            else #this is a potentially anchoring mate so print it out in BED
            {
                my $pos = $s[ 3 ];
                my $rl = length( $s[ 9 ] );
                print $afh qq[$ref\t$pos\t].($pos+$rl).qq[\t$name\n];
            }
        }
        if( $currentChr ne $ref ){print qq[Reading chromosome: $ref\n];$currentChr = $ref;}
    }
    close( $ffh );
    close( $afh );
    
    undef %candidates; #finished with this hash
    
    my $soutput = qq[$$.candidates.fasta.out];
    print qq[\nAligning candidate read sequences against transposon reference....\n];
    _run_ssaha2( $eRef, qq[$$.candidates.fasta], $soutput ) or die qq[Failed to run ssaha function\n];
	
    print qq[Parsing alignments....\n];
    my %anchors;
	open( my $sfh, $soutput ) or die qq[Failed to open ssaha output file: $!];
	while( <$sfh> )
	{
	    chomp;
	    next unless $_ =~ /^ALIGNMENT/;
	    my @s = split( /\s+/, $_ );
	    #    check min identity	  check min length
	    if( $s[ 10 ] >= $id && $s[ 9 ] >= $length && ! $anchors{ $s[ 2 ] } )
	    {
	        $anchors{ $s[ 2 ] } = $s[ 8 ] eq 'F' ? '+' : '-';
	    }
	}
	close( $sfh );
	
	#filter the BED file of anchor candidates to produce the final anchors file
	open( $afh, qq[>$output] ) or die $!;
	print $afh qq[$HEADER\n];
	open( my $cfh, qq[$$.candidate_anchors.bed] ) or die $!;
	while( <$cfh> )
	{
	    chomp;
	    my @s = split( /\t/, $_ );
	    if( $anchors{ $s[ 3 ] } )
	    {
	        print $afh qq[$_\n];
	    }
	}
	print $afh qq[$FOOTER\n]; #write an end of file marker
	close( $cfh );
	close( $afh );
	
	if( $clean )
	{
	    #delete the intermediate files
	    unlink( glob( qq[$$.*] ) );
	}
}

sub _findInsertions
{
    my $bam = shift;
    my $input = shift;
    my $ref = shift;
    my $output = shift;
    my $reads = shift;
    my $depth = shift;
    my $minQ = shift;
    my $clean = shift;
    
    _checkBinary( 'sort' ); #sort cmd required
    
    #read in all the files
    open( my $ifh, $input ) or die qq[Failed to open input file: $input\n];
    my $line = <$ifh>;chomp( $line );
    my $tempUnsorted = qq[$$.unsort_reads.bed];
    open( my $tfh, qq[>$tempUnsorted] ) or die qq[Failed to create temporary reads file\n];
    if( $line !~ /^#/ )
    {
        seek $ifh, 0, 0; #reset file handle
        while( <$ifh> )
        {
            chomp;
            my $fileName = $_;
            if( ! -f $fileName ){die qq[Input file does not contain file of file names. Cant find file: $fileName\n];}
            
            #check the eof markers are there from the discovery stage
            _checkDiscoveryOutput( $fileName );
            
            open( my $ffh, $fileName ) or die qq[Failed to open input file $fileName: $!];
            while( <$ffh> )
            {
                chomp;
                next unless $_ !~ /^#/;
                print $tfh qq[$_\n];
            }
        }
    }
    else
    {
        #check the eof markers are there from the discovery stage
        _checkDiscoveryOutput( $input );
        
        while( <$ifh> )
        {
            chomp;
            next unless $_ !~ /^#/;
            print $tfh qq[$_\n];
        }
    }
    close( $ifh );
    close( $tfh );
    
    #get the sample name(s) from the bam
    my $sampleName = _getBAMSampleName( $bam );
    
    #sort the calls by chr and position
    my $tempSorted = qq[$output.evidence];
    _sortBED( $tempUnsorted, $tempSorted );
    
    #convert to a region BED
    print qq[Calling initial rough boundaries of insertions....\n];
    my $rawTECalls = qq[$$.raw_calls.1.tab];
    _convertToRegionBED( $tempSorted, $sampleName, $rawTECalls );
    
    #remove calls with low supporting reads
    print qq[Removing calls with low read support....\n];
    my $rawTECalls1 = qq[$$.raw_calls.2.tab];
    open( $tfh, $rawTECalls ) or die $!;
    open( my $lfh, qq[>$rawTECalls1] ) or die $!;
    while( <$tfh> )
    {
        chomp;
        my @s = split( /\t/, $_ );
        if( $s[ 4 ] >= $reads )
        {
            print $lfh qq[$_\n];
        }
    }
    close( $tfh );
    
    #remove extreme depth calls
    print qq[Removing calls with extremely high depth (>$depth)....\n];
    my $rawTECalls2 = qq[$$.raw_calls.3.tab];
    _removeExtremeDepthCalls( $rawTECalls1, $bam, $depth, $rawTECalls2 );
    
    #attempt to work out where the breakpoint is
    print qq[Refining rough calls....\n];
    my $refinedTECalls = qq[$$.refined_calls.4.tab];
    #_findBreakPointCoverage( $rawTECalls2, $bam, $depth, $refinedTECalls );
    _refineBreakPoints( $rawTECalls2, $bam, $depth, $minQ, $ref, $refinedTECalls );
    
    #output calls in VCF format
    print qq[Creating VCF file of calls....\n];
    _outputCalls( $refinedTECalls, $sampleName, $ref, $output );
    
    if( $cleanup )
    {
        #clean up temporary files
        unlink( glob('$$.') ) or die qq[Failed to cleanup temporary files: $!];
    }
}

sub _refineBreakPoints
{
    my $bedin = shift;
    my $bam = shift;
    my $minDepth = shift;
    my $minMapQ = shift;
    my $reference = shift;
    my $outputBED = shift;
    
    open( my $ifh, $bedin ) or die $!;
	open( my $ofh, qq[>$outputBED] ) or die $!;
	while( <$ifh> )
	{
	    chomp;
	    my $originalCall = $_;
	    my @originalCallA = split( /\t/, $_ );
	    my $strain = (split( /\./, $originalCallA[3] ))[ 0 ];

	    my $start = $originalCallA[ 1 ];my $end = $originalCallA[ 2 ];my $chr = $originalCallA[ 0 ];
	    my $mid = int(($start + $end ) / 2);my $regStart = $mid - 600; $regStart = 1 if( $regStart < 1 );my $regEnd = $mid + 600;
	    
	    open( my $tfh, qq[samtools view -h -b $bam $chr:$regStart-$regEnd | samtools pileup -c -f $ref - | tail -1100 | head -1000 | ] ) or die $!;
	    my %depths;
	    while( <$tfh> )
	    {
	        chomp;my @s = split( /\t/, $_ );
	        my $d = ($s[8]=~tr/,\./x/); #count the depth of the bases that match the reference (i.e. sometimes at the breakpoint there are snps causing false depth)
	        if( $s[ 2 ] eq $s[ 3 ] )
	        {
	            $depths{ $s[ 1 ] } = $d; #if samtools thinks its not a real snp (i.e. dont want to consider depth at real snp positions
	        }
	        else{$depths{ $s[ 1 ] } = $s[ 7 ];}
	    }
	    close( $tfh );
	    
	    my @res = __local_min_max( %depths );
	    if( !@res || !$res[ 0 ] ){print qq[WARNING: no max/min returned for $originalCall\n];next;}
	    my %min = %{$res[ 0 ]};
	    my @positions = keys( %min );
	    
	    #sort by min depths
	    @positions = sort {$min{$a}<=>$min{$b}} @positions;
	    
	    #test each point to see if has the desired signature of fwd / rev pointing reads
	    my $found = 0;my $tested = 0;
	    my $lastRefIndex = -1;
	    while( $tested < 5 )
	    {
	        #check the distance to the set tested so far (i.e. dont want to retest with a cluster of local minima)
	        my $newIndex = $lastRefIndex + 1;
	        while( $newIndex < @positions )
	        {
	            #print qq[n: $newIndex\n];
	            my $closeby = 0;
	            for( my $j = 0; $j < $newIndex; $j ++ )
	            {#print qq[j: $j\n];
	                if( abs( $positions[$newIndex] - $positions[ $j ] ) < 100 ){$closeby = 1;last;}
	            }
	            #print qq[n1: $newIndex\n];
	            last if( $closeby == 0 );
	            $newIndex ++;
	        }
	        last if $newIndex == @positions;
	        $lastRefIndex = $newIndex;
	        my $depth = $min{$positions[$newIndex]};
	        my $refPos = $positions[ $newIndex ];
	        
	        last unless $depth < $minDepth;
	        
	        #test to see if lots of rp's either side
	        my $lhsFwd = 0; my $lhsRev = 0; my $rhsFwd = 0; my $rhsRev = 0;
	        
	        #also check the orientation of the supporting reads (i.e. its not just a random mixture of f/r reads overlapping)
	        my $cmd = qq[samtools view $bam $chr:].($refPos-300).qq[-].($refPos+300).qq[ | ];
	        open( $tfh, $cmd ) or die $!;
	        while( <$tfh> )
	        {
	            chomp;
	            my @s = split( /\t/, $_ );
	            next unless $s[ 4 ] > $minMapQ;
	            if( !( $s[ 1 ] & $$BAMFLAGS{'read_paired'} ) && ( $s[ 1 ] & $$BAMFLAGS{'mate_unmapped'} || $s[ 2 ] ne $s[ 6 ] ) )
	            {
	                #print qq[candidate: $s[1]\n];
	                if( $s[ 1 ] & $$BAMFLAGS{'reverse_strand'} ) #rev strand
	                {
	                    if( $s[ 3 ] < $refPos ){$lhsRev++;}else{$rhsRev++;}
	                }
	                else
	                {
	                    if( $s[ 3 ] < $refPos ){$lhsFwd++;}else{$rhsFwd++;}
	                }
	            }
	        }
	        
	        #check there are supporting read pairs either side of the depth minima
	        if( $lhsFwd > 5 && $rhsRev > 5 && ( $lhsRev == 0 || $lhsFwd / $lhsRev > 2 ) && ( $rhsFwd == 0 || $rhsRev / $rhsFwd > 2 ) )
	        {
	            print $ofh qq[$chr\t$refPos\t].($refPos+1).qq[\t$originalCallA[ 3 ]\t$originalCallA[ 4 ]\t$originalCallA[ 5 ]\n];
	            $found = 1;
	            last;
	        }
	        $tested ++;
	    }
	}
}

=pod
Idea is to take a list of bams for new samples (e.g. low cov),
and look in the region around the VCF of calls to see if there is some
support for the call in the new sample and output a new VCF with the
new genotypes called
=cut
sub _genotypeCallsMinimaTable
{
    my $bam_fofn = shift;
	my $input = shift;
    my $chromosome = shift;
	my $minDepth = shift;
	my $minMapQ = shift;
	my $ref = shift;
	my $output = shift;
	my $clean = shift;
	
	#get the list of sample names
    my %sampleBAM;
    open( my $tfh, $bams ) or die $!;
    while(<$tfh>)
    {
        chomp;
        my $bam = $_;
        die qq[Cant find BAM file: $_\n] unless -f $bam;
        die qq[Cant find BAM index for BAM: $bam\n] unless -f qq[$bam.bai];
        
        my $s = _getBAMSampleName( $bam );
        if( $s ){$sampleBAM{ $s } = $bam;}else{die qq[Failed to determine sample name for BAM: $bam\nCheck SM tag in the read group entries.\n];exit;}
    }close( $tfh );
    
    my $vcf = Vcf->new(file=>$input);
    $vcf->parse_header();
    my $vcf_out = Vcf->new();
    open( my $out, qq[>$output] ) or die $!;
    foreach my $sample ( keys( %sampleBAM ) )
	{
	    $vcf_out->add_columns( $sample );
	}
	_writeVcfHeader( $vcf_out, $out );
	
    while( my $entry = $vcf->next_data_hash() )
    {
        my $chr_ = $$entry{CHROM};
        my @ci = split( /,/, $$entry{INFO}{CIPOS} );
        my $pos = $$entry{POS};
        my $start = ($$entry{POS} + $ci[ 0 ]) > 1 ? $$entry{POS} + $ci[ 0 ] : 1;
        my $end = $$entry{POS} + $ci[ 1 ];
        
        foreach my $sample ( sort( keys( %sampleBAM ) ) )
        {
            my $call = _genotypeRegion($chr, $start, $end, $sampleBAM{ $sample }, $minDepth, $minMapQ, $ref );
            if( $call )
	        {
	            $$entry{gtypes}{$sample}{GT} = qq[<INS:ME>/<INS:ME>];
                $$entry{gtypes}{$sample}{GQ} = $call;
	        }
	        else
	        {
	            $$entry{gtypes}{$sample}{GT} = qq[./.];
                $$entry{gtypes}{$sample}{GQ} = '.';
	        }
        }
        $vcf->format_genotype_strings($$entry);
        print $out $vcf_out->format_line($$entry);
    }
    $vcf->close();
	close( $out );
}

sub _genotypeRegion
{
    my $chr = shift;
    my $start = shift;
    my $end = shift;
    my $bam = shift;
    my $minDepth = shift;
    my $minMapQ = shift;
    my $ref = shift;
    
    die qq[cant find bam: $bam\n] unless -f $bam;
    
    #check the min depth in the region is < minDepth
    my $regStart = $start - 200; my $regEnd = $end + 200;
    open( my $tfh, qq[samtools view -h -b $bam $chr:$regStart-$regEnd | samtools pileup -c -f $ref -N 1 - | tail -300 | head -200 | ] ) or die $!;
    my $minDepth_ = 100; my $minDepthPos = -1;
    while( <$tfh> )
    {
        chomp;my @s = split( /\t/, $_ );
	    my $d = ($s[8]=~tr/,\./x/); #count the depth of the bases that match the reference (i.e. sometimes at the breakpoint there are snps causing false depth)
	    if( $s[ 2 ] eq $s[ 3 ] && $d < $minDepth_ )
	    {
	        $minDepth_ = $d;$minDepthPos = $s[ 1 ];
	    }
	    elsif($s[ 7 ] < $minDepth_ ){$minDepth_ = $s[ 7 ];$minDepthPos = $s[ 1 ];}
    }
    close( $tfh );
    
    if( $minDepth_ > $minDepth ){return undef;} #no call - depth to high
    
    #also check the orientation of the supporting reads (i.e. its not just a random mixture of f/r reads overlapping)
    my $cmd = qq[samtools view $bam $chr:].($minDepthPos-300).qq[-].($minDepthPos+300).qq[ | ];
	open( $tfh, $cmd ) or die $!;
	my $lhsRev = 0; my $rhsRev = 0; my $lhsFwd = 0; my $rhsFwd = 0;
	while( <$tfh> )
	{
	    chomp;
	    my @s = split( /\t/, $_ );
	    next unless $s[ 4 ] > $minMapQ;
	    if( !( $s[ 1 ] & $$BAMFLAGS{'read_paired'} ) && ( $s[ 1 ] & $$BAMFLAGS{'mate_unmapped'} || $s[ 2 ] ne $s[ 6 ] ) )
	    {
	        #print qq[candidate: $s[1]\n];
	        if( $s[ 1 ] & $$BAMFLAGS{'reverse_strand'} ) #rev strand
	        {
	            if( $s[ 3 ] < $minDepthPos ){$lhsRev++;}else{$rhsRev++;}
	        }
	        else
	        {
	            if( $s[ 3 ] < $minDepthPos ){$lhsFwd++;}else{$rhsFwd++;}
	        }
	    }
	 }
	 
	 #N.B. Key difference is that only 1 side is required to have the correct ratio of fw:rev reads
	 if( $lhsFwd > 5 && $rhsRev > 5 && ( ( $lhsRev == 0 || $lhsFwd / $lhsRev > 2 ) || ( $rhsFwd == 0 || $rhsRev / $rhsFwd > 2 ) ) )
	 {
	     return ($lhsFwd+$rhsRev);
	 }
	 return undef;
}

#***************************INTERNAL HELPER FUNCTIONS********************

sub _getCandidateTEReadNames
{
    my $bam = shift;
    my $chr = shift;
    my $start = shift;
    my $end = shift;
    my $minAnchor = shift;
    
    my %candidates;
    
    print qq[Opening BAM ($bam) and getting initial set of candidate mates....\n];
    
    open( my $bfh, qq[samtools view $bam |] ) or die $!;
    my $currentChr = '';
    while ( my $samLine = <$bfh> )
    {
        chomp( $samLine );;
        my @sam = split( /\t/, $samLine );
        my $flag = $sam[ 1 ];;
        my $qual = $sam[ 4 ];
        my $name = $sam[ 0 ];
        my $ref = $sam[ 2 ];
        my $mref = $sam[ 6 ];
        my $rl = length( $sam[ 9 ] );
        
        #            read is not a duplicate
        if( ! ( $flag & $$BAMFLAGS{'duplicate'} ) && $qual >= $minAnchor && $rl >= $length ) #ignore pcr dups
        {
            #           read is mapped                       mate is unmapped
            if( ! ( $flag & $$BAMFLAGS{'unmapped'} ) && ( $flag & $$BAMFLAGS{'mate_unmapped'} ) )
            {
               $candidates{ $name } = $flag & $$BAMFLAGS{'1st_in_pair'} ? 2 : 1; #mate is recorded
            }
            #            read is mapped                      mate is mapped                                  not paired correctly
            elsif( ! ( $flag & $$BAMFLAGS{'unmapped'} ) && ! ( $flag & $$BAMFLAGS{'mate_unmapped'} ) && ! ( $flag && $$BAMFLAGS{'read_paired'} ) && $mref ne '=' )
            {
               $candidates{ $name } = $flag & $$BAMFLAGS{'1st_in_pair'} ? 2 : 1; #mate is recorded
            }
        }
        if( $currentChr ne $ref ){print qq[Reading chromosome: $ref\n];$currentChr = $ref;}
    }
    close( $bfh );
    
    return \%candidates;
}

sub _getBAMSampleName
{
    my $bam = shift;

    my @samples;
    open( my $bfh, qq[samtools view -H $bam |] );
    while( my $line = <$bfh> )
    {
        chomp( $line );
        next unless $line =~ /^\@RG/;
        my @s = split(/\t/, $line );
        if( $s[ 6 ] && $s[ 6 ] =~ /^(SM):(\w+)/ ){push(@samples, $2 );}
    }
    
    return @samples && @samples > 0 ? join( "_", @samples ) : undef; #if multiple samples - join the names into a string
}

sub _checkDiscoveryOutput
{
    my $file = shift;
    
    open( my $tfh, $file ) or die $!;
    my $line = <$tfh>;$line .= <$tfh>;chomp( $line );
    if( $line ne $HEADER ){die qq[Malformed header of input file: $file\n];}
    my $lastLine;
    while(<$tfh>){chomp;$lastLine=$_;}
    close( $tfh );
    
    if( $lastLine ne $FOOTER ){die qq[Malformed footer of input file: $file\n];}
    return 1;
}

#input is a list of samples and a bed file, output is a VCF + BED file of calls
sub _outputCalls
{
    my $calls = shift; #BED/tab format
    my $sample = shift;
    my $reference = shift;
    my $output = shift;
    
    open( my $vfh, qq[>$output] ) or die $!;
    
    my $vcf_out = Vcf->new();
    $vcf_out->add_columns($sample);
    
    my $header = _getVcfHeader($vcf_out);
    print $vfh $header;
    
    open( my $cfh, $calls ) or die qq[Failed to open TE calls file: $calls\n];
    while( <$cfh> )
    {
        chomp;
        my @s = split( /\t/, $_ );
        
        my $pos = int( ( $s[ 1 ] + $s[ 2 ] ) / 2 );
        my $refbase = _getReferenceBase( $reference, $s[ 0 ], $pos );
        my $ci1 = $s[ 1 ] - $pos;
        my $ci2 = $s[ 2 ] - $pos;
        
        my %out;
        $out{CHROM}  = $s[ 0 ];
        $out{POS}    = $pos;
        $out{ID}     = '.';
        $out{ALT}    = [];
        $out{REF}    = $refbase;
        $out{QUAL}   = $s[ 4 ];
        $out{FILTER} = ['NOT_VALIDATED'];
        if( $ci1 < 0 || $ci2 > 1 )
        {
            $out{INFO} = { IMPRECISE=>undef, SVTYPE=>'INS', CIPOS=>"$ci1,$ci2", NOT_VALIDATED=>undef };
        }
        else
        {
            $out{INFO} = { IMPRECISE=>undef, SVTYPE=>'INS', NOT_VALIDATED=>undef };
        }
        $out{FORMAT} = ['GT'];
        
        $out{gtypes}{$s[3]}{GT} = qq[<INS:ME>/<INS:ME>];
        $out{gtypes}{$s[3]}{GQ} = qq[$s[4]];
        
        $vcf_out->format_genotype_strings(\%out);
        print $vfh $vcf_out->format_line(\%out);
    }
    close( $cfh );
    close( $vfh );
}

#remove calls where there is very high depth (measured from pileup) in the region
sub _removeExtremeDepthCalls
{
	my $calls = shift;
	my $bam = shift;
	my $maxDepth = shift;
	my $outputbed = shift;
	
	open( my $cfh, $calls ) or die $!;
	open( my $ofh, ">$outputbed" ) or die $!;
	while( <$cfh> )
	{
		chomp;
		
		my @s = split( /\t/, $_ );
		
		my $start = $s[ 1 ] - 100 > 0 ? $s[ 1 ] - 50 : 0;
		my $end = $s[ 2 ] + 100;
		my $size = $end - $start;
		my $chr = $s[ 0 ];
		
		#get the avg depth over the region
		my $totalDepth = `samtools view -h $bam $chr:$start-$end | samtools pileup -S - |  awk -F"\t" '{SUM += \$4} END {print SUM}'`;chomp( $totalDepth );
		my $avgDepth = $totalDepth / $size;
		if( $avgDepth < $maxDepth )
		{
			print $ofh qq[$_\n];
		}
		else
		{
		    print "Excluding call due to high depth: $_ AvgDepth: $avgDepth\n"
		}
	}
	close( $cfh );
	close( $ofh );
	
	return 1;
}

#convert the individual read calls to calls for putative TE insertion calls
#output is a BED file and a VCF file of the calls
sub _convertToRegionBED
{
	my $calls = shift;
	my $id = shift;
	my $outputbed = shift;
	
	open( my $ofh, qq[>$outputbed] ) or die $!;
	open( my $cfh, $calls ) or die $!;
	my $lastEntry = undef;
	my $regionStart = 0;
	my $regionEnd = 0;
	my $regionChr = 0;
	my $reads_in_region = 0;
	my %startPos; #all of the reads must start from a different position (i.e. strict dup removal)
	while( <$cfh> )
	{
		chomp;
		my @s = split( /\t/, $_ );
		if( ! defined $lastEntry )
		{
			$regionStart = $s[ 1 ];
			$regionEnd = $s[ 1 ];
			$regionChr = $s[ 0 ];
			$reads_in_region = 1;
			$startPos{ $s[ 1 ] } = 1;
		}
		elsif( $s[ 0 ] ne $regionChr )
		{
			#done - call the region
			my @s1 = split( /\t/, $lastEntry );
			$regionEnd = $s1[ 1 ];
			my $size = $regionEnd - $regionStart; $size = 1 unless $size > 0;
			print $ofh "$regionChr\t$regionStart\t$regionEnd\t$id\t$reads_in_region\n";
			
			$reads_in_region = 1;
			$regionStart = $s[ 1 ];
			$regionEnd = $s[ 1 ];
			$regionChr = $s[ 0 ];
			%startPos = ();
			$startPos{ $s[ 1 ] } = 1;
		}
		elsif( $s[ 1 ] - $regionEnd > $MAX_READ_GAP_IN_REGION )
		{
			#call the region
			my @s1 = split( /\t/, $lastEntry );
			$regionEnd = $s1[ 1 ];
			my $size = $regionEnd - $regionStart; $size = 1 unless $size > 0;
			print $ofh "$regionChr\t$regionStart\t$regionEnd\t$id\t$reads_in_region\n";
			
			$reads_in_region = 1;
			$regionStart = $s[ 1 ];
			$regionChr = $s[ 0 ];
			
			%startPos = ();
			$startPos{ $s[ 1 ] } = 1;
		}
		else
		{
			#read is within the region - increment
			if( ! defined( $startPos{ $s[ 1 ] } ) )
			{
				$reads_in_region ++;
				$regionEnd = $s[ 1 ];
				$startPos{ $s[ 1 ] } = 1;
			}
		}
		$lastEntry = $_;
	}
	my $size = $regionEnd - $regionStart; $size = 1 unless $size > 0;
	print $ofh "$regionChr\t$regionStart\t$regionEnd\t$id\t$reads_in_region\n";
	close( $cfh );
	close( $ofh );
	
	return 1;
}

sub _sortBED
{
    my $input = shift;
    my $output = shift;
    
    croak qq[Cant find intput file for BED sort: $input\n] unless -f $input;
    system( qq[sort -k 1,1d -k 2,2n $input > $output] ) == 0 or die qq[Failed to sort BED file: $input\n];
    return 1;
}

sub _checkBinary
{
    my $binary = shift;
    
    if( ! `which $binary` )
    {
        croak qq[Error: Cant find required binary $binary\n];
    }
}

sub _run_ssaha2
{
    my $ref = shift;
    my $fasta = shift;
    my $output = shift;
    
    #run ssaha in order to determine the reads that hit the retro ref
	system( qq[ssaha2 -solexa $ref $fasta | egrep "ALIGNMENT|SSAHA2" > $output] ) == 0 or die qq[ERROR: failed to run ssaha of candidate reads\n];
	
	#check the program finished successfully...
	open( my $tfh, $output ) or die qq[Failed to open ssaha output file: $!];
	my $lastLine;
	while( <$tfh>)
	{
	    chomp;
	    $lastLine = $_;
	}
	close( $tfh );
	
	if( $lastLine !~ /^SSAHA2 finished\.$/ ){ die qq[SSAHA2 did not run to completion - please check: $output\n];}
	
	return 1;
}

#creates all the tags necessary for the VCF files
sub _getVcfHeader
{
    my $vcf_out = shift;
    
    ##INFO=<ID=SVTYPE,Number=1,Type=String,Description="Type of structural variant">
    $vcf_out->add_header_line( {key=>'INFO',ID=>'SVTYPE',Number=>'1',Type=>'String', Description=>'Type of structural variant'} );
    
    ##ALT=<ID=INS:ME,Description="Insertion of a mobile element">
    $vcf_out->add_header_line( {key=>'ALT', ID=>'INS:ME', Type=>'String', Description=>"Insertion of a mobile element"} );
    
    ##INFO=<ID=IMPRECISE,Number=0,Type=Flag,Description="Imprecise structural variation">
    $vcf_out->add_header_line( {key=>'INFO', ID=>'IMPRECISE', Number=>'0', Type=>'Flag', Description=>'Imprecise structural variation'} );
    
    ##INFO=<ID=CIPOS,Number=2,Type=Integer,Description="Confidence interval around POS for imprecise variants">
    $vcf_out->add_header_line( {key=>'INFO', ID=>'CIPOS', Number=>'2', Type=>'Integer,Description', Description=>'Confidence interval around POS for imprecise variants' } );
    
    ##FORMAT=<ID=GT,Number=1,Type=Integer,Description="Genotype">
    $vcf_out->add_header_line({key=>'FORMAT',ID=>'GT',Number=>'1',Type=>'String',Description=>"Genotype"});
    
    ##FORMAT=<ID=GQ,Number=1,Type=Float,Description="Genotype quality">
    $vcf_out->add_header_line( {key=>'FORMAT', ID=>'GQ', Number=>'1', Type=>'Float,Descriptions', Description=>'Genotype quality'} );
    
    $vcf_out->add_header_line( {key=>'INFO', ID=>'NOT_VALIDATED', Number=>'0', Type=>'Flag', Description=>'Not validated either computationally or experimentally'} );
    $vcf_out->add_header_line( {key=>'INFO', ID=>'COMP_VALIDATED', Number=>'0', Type=>'Flag', Description=>'Computationally validated with local assembly'} );
    
    return $vcf_out->format_header();
}

sub _revCompDNA
{
	croak "Usage: revCompDNA string\n" unless @_ == 1;
	my $seq = shift;
	$seq= uc( $seq );
	$seq=reverse( $seq );
	
	$seq =~ tr/ACGTacgt/TGCAtgca/;
	return $seq;
}

#from an indexed fasta - get the reference base at a specific position
sub _getReferenceBase
{
    my $fasta = shift;
    my $chr = shift;
    my $pos = shift;
    
    my $base = `samtools faidx $fasta $chr:$pos-$pos | tail -1`;
    chomp( $base );
    
    if( length( $base ) != 1 && $base !~ /acgtnACGTN/ ){die qq[Failed to get reference base at $chr:$pos-$pos: $base\n]}
    return $base;
}

sub _local_min_max
{
    my %depths = @_;
    return undef unless keys( %depths ) > 1;
    
    my %minima = ();
    my %maxima = ();
    my $prev_cmp = 0;
    
    my @positions = keys( %depths );
    for( my $i=0;$i<@positions-1;$i++)
    {
        my $cmp = $depths{$positions[$i]} <=> $depths{$positions[$i+1]};
        if ($cmp && $cmp != $prev_cmp) 
        {
            $minima{ $positions[ $i ] } = $depths{ $positions[ $i ] };
            $maxima{ $positions[ $i ] } = $depths{ $positions[ $i ] };
            $prev_cmp = $cmp;
        }
    }
    
    $minima{ $positions[ -1 ] } = $depths{ $positions[ -1 ] } if $prev_cmp >= 0;
    $maxima{ $positions[ -1 ] } = $depths{ $positions[ -1 ] } if $prev_cmp >= 0;
    
    return (\%minima, \%maxima);
}
