library(dplyr)
library(aws.s3)

### Get file from AWS S3 bucket ###
s3BucketName = scan("s3-bucket-name.txt", what="txt")
readRenviron(".Renviron")
Sys.setenv(
  "AWS_ACCESS_KEY_ID"=Sys.getenv("AWS_ACCESS_KEY_ID"),
  "AWS_SECRET_ACCESS_KEY"=Sys.getenv("AWS_SECRET_ACCESS_KEY"),
  "AWS_DEFAULT_REGION"=Sys.getenv("AWS_DEFAULT_REGION")
)
lotto = s3read_using(
  read.csv,
  object='lotto-results-clean.csv',
  bucket=s3BucketName
  ) %>%
  select(-1) %>% # ignore first column (row index)
  rename("1"="X1", "2"="X2", "3"="X3", "4"="X4", "5"="X5", "6"="X6", "7"="X7")
# # Temporary - local purposes only:
# lotto = read.csv("./data/lotto_clean.csv", check.names=F)
### ###

### Dataset Options ###
lotto_clean = lotto %>% filter((`Draw` >= 575) | (`Draw` <= 275)) # ignore outliers
biweekly = lotto %>% filter(`Draw` >= 1479) # first time bi-weekly draws
smartplay = lotto %>%
  filter(`Date` >= "2018-05-30") %>% # first implemented
  filter(!(`Date` >= "2019-10-22" & `Date` <= "2019-10-29")) %>% # fire event
  filter(!(`Date` >= "2020-03-25" & `Date` <= "2019-04-27")) # L4 lockdown

datasets = list( 
  "Lotto" = lotto,
  "Lotto-Clean" = lotto_clean,
  "Bi-Weekly" = biweekly,
  "Smartplay" = smartplay
)
### ###

### Default Predictions Dataframe Layout ###
rng_df_default = data.frame("1"=integer(0),  "2"=integer(0), "3"=integer(0), 
                            "4"=integer(0), "5"=integer(0), "6"=integer(0), 
                            "PB"=integer(0), "Mode"=character(0),
                            "Model"=character(0), "Dataset"=character(0), 
                            "Resamples"=integer(0), "Draw"=integer(0),
                            check.names=F)
### ###

##### PREDICTION GENERATOR #####
## MAIN CONTROL FOR GENERATING PREDICTIONS **********************
get_pred_line = function(df, nBalls, nTimes, model) {
  if (model %in% c('prop', 'rev.prop', 'binom')) {
    return( get_bayes_pred_line(df, nTimes, model) )
  } else if (model %in% c('exp', 'rev.exp')) {
    return( get_exp_pred_line(df, nBalls, nTimes, model) )
  } else if (model %in% c('pois', 'rev.pois')) {
    return( get_pois_pred_line(df, nBalls, nTimes, model) )
  } else if (model %in% c('kde', 'rev.kde')) {
    return( get_density_pred_line(df, nBalls, nTimes, model) )
  } else { # random model
    return( get_rand_pred_line(nBalls, nTimes) )
  }
}

## GENERAL FUNCTION USED FOR ALL MODELS
get_most_common_line = function(preds_mat) { # given a matrix of predicted values (UNIVERSAL)
  N = ncol(preds_mat)
  nrows = nrow(preds_mat)
  chosen = numeric(N)
  for (i in 1:N) {
    counts = table(preds_mat[1:nrows, i])
    counts[as.character(chosen[1:i])] = -1 # careful not to mix index with character of index!
    max_freq_nums = as.integer(names(which.max(counts)))
    if (length(max_freq_nums) > 1) {max_freq_nums = sample(max_freq_nums, size=1)} # random tie-breaker
    chosen[i] = max_freq_nums
  }
  return(chosen) # returns vector for one prediction line
}

## RANDOM MODEL PREDICTIONS ##
get_rand_pred_line = function(nBalls, nTimes) {
  rand_pred_line = replicate(nTimes, {sample(1:40, size=min(6,nBalls))}) %>% t() %>%
    get_most_common_line()
  if (nBalls == 7) {
    pb_pred = replicate(nTimes, {sample(1:10, size=1)}) %>% t() %>%
      get_most_common_line()
    return(c(rand_pred_line, pb_pred))
  }
  return(rand_pred_line)
}

## KERNEL DENSITY ESITMATION PREDICTIONS (KDE) ##
get_density_pred_line = function(df, nBalls, nTimes, model) {
  # Generate Poisson Probabilities
  probs_lst = generate_density_probs(df, model) # list of probs. for every ball number in every ball order
  # Resample One Poisson Line nTimes Using Generated Probabilities
  pred_line = replicate(nTimes, {get_density_line(probs_lst)}) %>% t() %>% # matrix of predicted numbers
    get_most_common_line()
  return(pred_line) # returns a vector (one line of bayesian prediction)
}
# Generate Poisson Prediction Line
get_density_line = function(probs_lst) {
  N = length(probs_lst)
  maxBalls = c(rep(40,6), 10)
  balls = numeric(N)
  for (i in 1:N) { # using for-loop because have incrementally update
    ball_order_probs = probs_lst[[i]]
    if (i < 7) {ball_order_probs[balls] = 0} # ignore already chosen balls
    balls[i] = sample(1:maxBalls[i], size=1, prob=ball_order_probs)
  }
  return(balls)
}
generate_density_probs = function(df, model) {
  # Setup
  N = ncol(df) # 4, 6, or 7
  maxBalls = c(rep(40,6), 10)
  # Extract times since last drawn for each ball number in each ball order
  times_since_drawn = lapply(1:N, get_times_since_drawn, df, maxBalls)
  # Extract latest times since last drawn for each ball number in each ball order
  latest_times_since_drawn = lapply(times_since_drawn, function(lst){
    sapply(lst, function(vec){vec[1]}) # first element from each ball number
  })
  # Extract the wait time between draws for each ball number in each ball order
  wait_times = lapply(times_since_drawn, get_wait_times)
  # 
  density_probs = lapply(1:N, function(ball_order) {
    ball_num_odds = sapply(1:maxBalls[ball_order], function(ball_num){
      current_wait_time = latest_times_since_drawn[[ball_order]][ball_num]
      density_fit = density(wait_times[[ball_order]][ball_num][[1]])
      density_pred = max(approx(x=density_fit$x, y=density_fit$y, xout=current_wait_time)$y, 0, na.rm=T)
      density_pred
    })
    ball_num_odds # don't need to standardise -- sample() will handle it
  })
  if (model == 'rev.pois') {density_probs = lapply(density_probs, function(x){1 - x})}
  return(density_probs)
}
## Generate one line of Density predictions
density_one_line = function(probs_lst) {
  N = length(probs_lst)
  maxBalls = c(rep(40,6), 10)
  balls = numeric(N)
  for (i in 1:N) { # using for-loop because have incrementally update
    ball_order_probs = probs_lst[[i]]
    if (i < 7) {ball_order_probs[balls] = 0} # ignore already chosen balls
    balls[i] = sample(1:maxBalls[i], size=1, prob=ball_order_probs)
  }
  return(balls)
}
##### MAIN NUMBER GENERATING PROCESS FOR DENSITY FUNCTION #####
get_density_preds = function(df, strike, pb, nLines, nTimes=1) {
  # Generate density Probabilities Per Ball Number Per Ball Order
  probs = generate_density_probs(df)
  density_probs = probs$`density_probs`
  rev_density_probs = probs$`rev_density_probs`
  # Generate Predictions (NOTE: Replicating here to avoid recalculating probabilities)
  density_preds = replicate(nLines, {density_one_line_resample(nTimes, density_probs)}) %>%
    t() %>% as_tibble() %>% mutate(`Model`='Density', `nTimes`=nTimes)
  rev_density_preds = replicate(nLines, {density_one_line_resample(nTimes, rev_density_probs)}) %>%
    t() %>% as_tibble() %>% mutate(`Model`='Reverse Density', `nTimes`=nTimes)
  return(rbind(density_preds, rev_density_preds))
}
density_one_line_resample = function(nTimes, probs) {
  replicate(nTimes, {density_one_line(probs)}) %>% t() %>% # matrix of sampled nums
    get_most_common_line() # get most common nums as ONE LINE PREDICTION (vector)
}

## POISSON MODEL PREDICTIONS ##
get_pois_pred_line = function(df, nBalls, nTimes, model) {
  # Generate Poisson Probabilities
  probs_lst = generate_pois_probs(df, model) # list of probs. for every ball number in every ball order
  # Resample One Poisson Line nTimes Using Generated Probabilities
  pred_line = replicate(nTimes, {get_pois_line(probs_lst)}) %>% t() %>% # matrix of predicted numbers
    get_most_common_line()
  return(pred_line) # returns a vector (one line of bayesian prediction)
}
# Generate Poisson Prediction Line
get_pois_line = function(probs_lst) {
  N = length(probs_lst)
  maxBalls = c(rep(40,6), 10)
  balls = numeric(N)
  for (i in 1:N) { # using for-loop because have incrementally update
    ball_order_probs = probs_lst[[i]]
    if (i < 7) {ball_order_probs[balls] = 0} # ignore already chosen balls
    balls[i] = sample(1:maxBalls[i], size=1, prob=ball_order_probs)
  }
  return(balls)
}
### GENERATE POISSON PROBABILITIES ###
generate_pois_probs = function(df, model) {
  # Setup
  N = ncol(df) # 4, 6, or 7
  maxBalls = c(rep(40,6), 10)
  # Extract times since last drawn for each ball number in each ball order
  times_since_drawn = lapply(1:N, get_times_since_drawn, df, maxBalls)
  # Extract latest times since last drawn for each ball number in each ball order
  latest_times_since_drawn = lapply(times_since_drawn, function(lst){
    sapply(lst, function(vec){vec[1]}) # first element from each ball number
  })
  # Extract the wait time between draws for each ball number in each ball order
  wait_times = lapply(times_since_drawn, get_wait_times)
  # Extract the average rate for each ball number in each ball order
  wait_time_rates = lapply(wait_times, function(ball_order_lst){sapply(ball_order_lst, median)})
  # 
  pois_probs = lapply(1:N, function(ball_order) {
    ball_num_odds = sapply(1:maxBalls[ball_order], function(ball_num) {
      dpois(
        x=latest_times_since_drawn[[ball_order]][ball_num],
        lambda=wait_time_rates[[ball_order]][ball_num]
      )
    })
    ball_num_odds/sum(ball_num_odds) # make probability (0-1 standardise)
  })
  if (model == 'rev.pois') {pois_probs = lapply(pois_probs, get_reverse_probs)}
  return(pois_probs)
}
##### MAIN NUMBER GENERATING PROCESS FOR POISSON #####
get_pois_preds = function(df, strike, pb, nLines, nTimes=1) {
  # Generate Exponential Probabilities Per Ball Number Per Ball Order
  probs = generate_pois_probs(df)
  pois_probs = probs$`pois_probs`
  rev_exp_probs = probs$`rev_pois_probs`
  # Generate Predictions (NOTE: Replicating here to avoid recalculating probabilities)
  pois_preds = replicate(nLines, {pois_one_line_resample(nTimes, pois_probs)}) %>%
    t() %>% as_tibble() %>% mutate(`Model`='Poisson', `nTimes`=nTimes)
  rev_pois_preds = replicate(nLines, {pois_one_line_resample(nTimes, rev_exp_probs)}) %>%
    t() %>% as_tibble() %>% mutate(`Model`='Reverse Poisson', `nTimes`=nTimes)
  return(rbind(pois_preds, rev_pois_preds))
}
pois_one_line_resample = function(nTimes, probs) {
  replicate(nTimes, {exp_one_line(probs)}) %>% t() %>% # NOTE: CAN USE EXP_ONE_LINE() FOR POISSON
    get_most_common_line() # get most common nums as ONE LINE PREDICTION (vector)
}

## EXPONENTIAL MODEL PREDICTIONS ##
get_exp_pred_line = function(df, nBalls, nTimes, model) {
  # Generate Exponential Probabilities
  probs_lst = generate_exp_probs(df, nBalls, model) # list of probs. for every ball number in every ball order
  # Resample One Exponential Line nTimes Using Generated Probabilities
  pred_line = replicate(nTimes, {get_exp_line(probs_lst)}) %>% t() %>% # matrix of predicted numbers
    get_most_common_line()
  return(pred_line) # returns a vector (one line of bayesian prediction)
}
# Generate Exponential Prediction Line
get_exp_line = function(probs_lst) {
  N = length(probs_lst)
  maxBalls = c(rep(40,6), 10)
  balls = numeric(N)
  for (i in 1:N) { # using for-loop because have incrementally update
    ball_order_probs = probs_lst[[i]]
    if (i < 7) {ball_order_probs[balls] = 0} # ignore already chosen balls
    balls[i] = sample(1:maxBalls[i], size=1, prob=ball_order_probs)
  }
  return(balls)
}
# Generate Exponential Probabilities
generate_exp_probs = function(df, N, model) {
  # Setup
  maxBalls = c(rep(40,6), 10)
  # Extract times since last drawn for each ball number in each ball order
  times_since_drawn = lapply(1:N, get_times_since_drawn, df, maxBalls)
  # Extract latest times since last drawn for each ball number in each ball order
  latest_times_since_drawn = lapply(times_since_drawn, function(lst){
    sapply(lst, function(vec){vec[1]}) # first element from each ball number
  })
  # Extract the wait time between draws for each ball number in each ball order
  wait_times = lapply(times_since_drawn, get_wait_times)
  # Extract the average rate for each ball number in each ball order
  wait_time_rates = lapply(wait_times, function(ball_order_lst) {
    sapply(ball_order_lst, function(ball_num_lst){1/median(ball_num_lst)}) # using median > mean (median better captures center of a skewed distribution)
  })
  # 
  exp_probs = lapply(1:N, function(ball_order) {
    ball_num_odds = sapply(1:maxBalls[ball_order], function(ball_num) {
      dexp(
        x=latest_times_since_drawn[[ball_order]][ball_num],
        rate=wait_time_rates[[ball_order]][ball_num]
      )
    })
    ball_num_odds/sum(ball_num_odds) # make probability (0-1 standardise)
  })
  if (model == 'rev.exp') {exp_probs = lapply(exp_probs, get_reverse_probs)}
  return(exp_probs)
}
# Get the times since ball drawn for each ball number (HELPER TO generate_exp_probs())
get_times_since_drawn = function(idx, df, maxBalls) { # col should be a ball order column
  nBalls = maxBalls[idx]
  lapply(1:nBalls, function(num){which(df[idx] == num)})
}
# Calculate the wait times (difference) between each draw for each ball number (HELPER TO generate_exp_probs())
get_wait_times = function(col_lst) { # lst should be for one ball order
  lapply(col_lst, diff)
}
# Reverse Exponential Probabilities (HELPER TO generate_exp_probs())
get_reverse_probs = function(ball_order_vec) {
  middle = median(ball_order_vec)
  reverse = middle - (ball_order_vec - middle)
  reverse = reverse + abs(min(reverse) - 1e-4) # shift up incase of negatives (plus some to avoid 0 probability)
  reverse/sum(reverse) # normalise
}

## BAYESIAN MODEL PREDICTIONS ##
get_bayes_pred_line = function(df, nTimes, model) {
  # Generate Counts (Evidence) ONCE HERE!!!
  ball_order_counts = lapply(df, table)
  ball_order_props = lapply(ball_order_counts, prop.table) # list of prop.tables() for each ball order (from the given df)
  ball_order_evidence = list(
    'counts' = ball_order_counts,
    'props' = ball_order_props
  )
  # Resample One Bayes Line nTimes
  pred_line = replicate(nTimes, {get_bayes_line(ball_order_evidence, model)}) %>% t() %>% # matrix of predicted numbers
    get_most_common_line()
  return(pred_line)
}
get_bayes_line = function(evidence_lst, ll) {
  counts = evidence_lst$`counts`
  props = evidence_lst$`props`
  evidence = props
  if (ll == 'binom') {evidence = counts}
  nBalls = length(evidence)
  maxBalls = c(rep(40,6), 10)
  priors = c(1/40:35, 1/10)
  
  preds = numeric(nBalls)
  for (i in 1:nBalls) { # Note: using for-loop since apply-loops cannot alter variables outside its scope/function
    ball_order_evidence = evidence[[i]]
    if (i <= 6) {
      ball_order_evidence[as.character(preds[preds != 0])] = 0 # ignore drawn balls (only for non-powerball columns)
    }
    preds[i] = general_bayes(evidence=ball_order_evidence, maxBall=maxBalls[i], ll=ll, prior=priors[i])
  }
  return(preds)
}
general_bayes = function(evidence, maxBall, ll, prior) { # nums_drawn either df (lotto) or column vector (strike)
  ### Likelihood ###
  likelihoods = list(
    "prop" = evidence,
    "rev.prop" = (1-evidence)/sum((1-evidence)),
    "binom" = get_binom_likelihood(evidence, ll, prior)
  )
  likelihood = likelihoods[[ll]]
  ### Posterior ###
  prob_h_given_e = prior * likelihood
  posterior = prob_h_given_e / sum(prob_h_given_e)
  ### Predictions ###
  return(sample(1:maxBall, size=1, prob=posterior)) # returns 1 ball
}
get_binom_likelihood = function(evidence, ll, prior) { # PURELY TO AVOID WARNING()!
  if (ll != 'binom') {return()}
  else {
    return(
      dbinom(x=evidence, size=sum(evidence), prob=prior) # N := number of trials (sum(evidence)); k := number of successes (being drawn) (evidence)
    )
  }
}